import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ArtworkFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let path = request.url!.path
            var status = 200
            var response: [String: Any]
            if path.hasSuffix("models") {
                precondition(request.httpMethod == "GET")
                response = ["data": [
                    ["id": "vision-only", "modalities": ["input": ["text", "image"], "output": ["text"]]],
                    ["id": "new-image-model", "type": "image"],
                    ["id": "new-multimodal", "modalities": ["output": ["text", "image"]]]
                ]]
            } else {
                precondition(request.httpMethod == "POST", "Image generation must POST; GET with a body fails with NSURLError -1103")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                var bodyData = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bodyData.append(contentsOf: buffer.prefix(count)) }
                }
                if path == "/v4/ai/image-model" {
                    precondition(request.value(forHTTPHeaderField: "ai-image-model-specification-version") == "4")
                    precondition(request.value(forHTTPHeaderField: "ai-model-id") == "openai/gpt-image-2")
                    let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
                    precondition(body["size"] as? String == "1024x1024")
                    precondition(body["model"] == nil && body["response_format"] == nil)
                    let options = body["providerOptions"] as! [String: [String: String]]
                    precondition(options["openai"]?["background"] == "transparent")
                    if let files = body["files"] as? [[String: String]] {
                        precondition(files[0]["mediaType"] == "image/png")
                        precondition(Data(base64Encoded: files[0]["data"]!) == Data("reference".utf8))
                    }
                    response = ["images": [Data("gateway".utf8).base64EncodedString()]]
                } else if request.url?.host == "ai-gateway.vercel.sh", path.contains("images/") {
                    // Regression: the old unsupported Gateway route must never be requested.
                    client?.urlProtocol(self, didFailWithError: URLError(.dataLengthExceedsMaximum)); return
                } else if path.contains("edits") {
                    let text = String(decoding: bodyData, as: UTF8.self)
                    precondition(text.contains("name=\"image\"; filename=\"reference.png\""))
                    precondition(text.contains("name=\"background\"\r\n\r\ntransparent"))
                    response = ["data": [["b64_json": Data("edit".utf8).base64EncodedString()]]]
                } else {
                    let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
                    let model = body["model"] as! String
                    if model == "denied" { status = 401; response = ["error": ["message": "secret-provider-body"]] }
                    else if path.contains("chat/completions") {
                        precondition((body["modalities"] as! [String]).contains("image"))
                        precondition(body["background"] == nil)
                        let content = ((body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
                        precondition((content[0]["text"] as! String).contains("#00FF00"))
                        response = ["choices": [["message": ["images": [["image_url": ["url": "data:image/png;base64," + Data("chat".utf8).base64EncodedString()]]]]]]]
                    } else {
                        precondition(path.hasSuffix("images/generations"))
                        precondition(body["background"] as? String == "transparent")
                        precondition(body["output_format"] as? String == "png")
                        response = ["data": [["b64_json": Data("native".utf8).base64EncodedString()]]]
                    }
                }
            }
            let data = try JSONSerialization.data(withJSONObject: response)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct ArtworkTests {
    static func main() async throws {
        precondition(ArtworkModel.parse(["id": "future-model", "type": "image"]) != nil)
        precondition(ArtworkModel.parse(["id": "vision", "modalities": ["input": ["image"], "output": ["text"]]]) == nil)
        precondition(ArtworkModel.parse(["id": "gpt-image-2", "output_modalities": ["text"]]) == nil)
        precondition(ArtworkModel.parse(["id": "gpt-image-2"])?.nativeTransparency == true)
        precondition(ArtworkModel.parse(["id": "unknown"]) == nil)
        precondition(ArtworkModel.parse(["id": "future", "capabilities": ["image_generation": true]]) != nil)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArtworkFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var settings = ArtworkConfiguration(); settings.provider = .gateway
        settings.model = .init(id: "openai/gpt-image-2", name: "Image", chat: false)
        var api = ArtworkAPI(configuration: settings, key: "fixture-key", session: session)
        let models = try await api.models()
        precondition(models.count == 2 && models.contains { $0.id == "new-multimodal" && $0.chat })
        let gateway = try await api.generate(prompt: "person", transparent: true, reference: nil)
        precondition(String(decoding: gateway, as: UTF8.self) == "gateway")
        let gatewayEdit = try await api.generate(prompt: "same person", transparent: true, reference: Data("reference".utf8))
        precondition(String(decoding: gatewayEdit, as: UTF8.self) == "gateway")
        settings.provider = .endpoint
        api = ArtworkAPI(configuration: settings, key: "fixture-key", session: session)
        let native = try await api.generate(prompt: "person", transparent: true, reference: nil)
        precondition(String(decoding: native, as: UTF8.self) == "native")
        let edit = try await api.generate(prompt: "same person", transparent: true, reference: Data("reference".utf8))
        precondition(String(decoding: edit, as: UTF8.self) == "edit")
        settings.model = .init(id: "future-multimodal", name: "Multimodal", chat: true)
        api = ArtworkAPI(configuration: settings, key: "fixture-key", session: session)
        let chat = try await api.generate(prompt: "person", transparent: true, reference: nil)
        precondition(String(decoding: chat, as: UTF8.self) == "chat")
        settings.model = .init(id: "denied", name: "Denied", chat: false)
        do {
            _ = try await ArtworkAPI(configuration: settings, key: "fixture-key", session: session).generate(prompt: "x", transparent: true, reference: nil)
            preconditionFailure("HTTP errors must fail")
        } catch { precondition(!error.localizedDescription.contains("secret-provider-body")) }
        // Key both boundary green and enclosed green gaps, preserving the red subject.
        let w = 7, h = 7
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            pixels[i + 3] = 255
            if (2...4).contains(x) && (2...4).contains(y) { pixels[i] = 255 }
            else { pixels[i + 1] = 255 }
        } }
        pixels[(3 * w + 3) * 4] = 0; pixels[(3 * w + 3) * 4 + 1] = 255
        ArtworkPNG.key(&pixels, width: w, height: h)
        precondition(pixels[3] == 0 && pixels[(2 * w + 2) * 4 + 3] == 255 && pixels[(3 * w + 3) * 4 + 3] == 0)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); precondition(CGImageDestinationFinalize(destination))
        let png = try ArtworkPNG.encode(encoded as Data, keyGreen: false, requireAlpha: true)
        precondition(CGImageSourceCreateWithData(png as CFData, nil) != nil)
        do { _ = try ArtworkPNG.encode(Data("HTML".utf8), keyGreen: true, requireAlpha: true); preconditionFailure() } catch {}
        print("Artwork: capability filtering, image/chat/edit routing, native transparency, HTTP errors, keyout and PNG validation passed")
    }
}
