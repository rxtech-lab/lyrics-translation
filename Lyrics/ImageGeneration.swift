import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ArtworkModel: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let chat: Bool
    var nativeTransparency: Bool {
        let family = id.lowercased().split(separator: "/").last.map(String.init) ?? ""
        return family.hasPrefix("gpt-image-") || family == "chatgpt-image-latest"
    }

    /// Output capabilities take precedence over names. Vision input alone is never image generation.
    static func parse(_ value: [String: Any]) -> ArtworkModel? {
        guard let id = value["id"] as? String else { return nil }
        let modalities = value["modalities"] as? [String: Any]
        let architecture = value["architecture"] as? [String: Any]
        let explicit = (modalities?["output"] as? [String]) ?? (value["output_modalities"] as? [String])
            ?? (architecture?["output_modalities"] as? [String])
        let type = value["type"] as? String
        let capabilities = value["capabilities"] as? [String: Any]
        let tags = value["capabilities"] as? [String] ?? []
        let advertised = explicit != nil || type != nil || capabilities != nil || !tags.isEmpty
        let image = explicit?.contains("image") == true || type == "image"
            || capabilities?["image_generation"] as? Bool == true || tags.contains("image_generation")
        // OpenAI's /models omits modalities. Only recognize image-generation families there.
        let family = id.lowercased().split(separator: "/").last.map(String.init) ?? ""
        let known = family.hasPrefix("gpt-image-") || family == "chatgpt-image-latest" || family.hasPrefix("dall-e-")
        guard image || (!advertised && known) else { return nil }
        return Self(id: id, name: value["name"] as? String ?? id,
                    chat: type != "image" && explicit?.contains("text") == true)
    }
}

struct ArtworkConfiguration: Codable, Sendable {
    enum Provider: String, CaseIterable, Codable, Sendable { case codex = "Codex", gateway = "Vercel AI Gateway", endpoint = "OpenAI-compatible" }
    var provider: Provider = .codex
    var endpoint = "https://api.openai.com/v1"
    var model: ArtworkModel?
    var baseURL: String { provider == .gateway ? "https://ai-gateway.vercel.sh/v1" : endpoint }
    static let defaultsKey = "lyricArtworkConfiguration"
    static func load() -> Self {
        UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func save() throws { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey) }
}

struct ArtworkAPI: Sendable {
    let configuration: ArtworkConfiguration
    let key: String
    var session: URLSession = .shared

    func request(_ path: String) throws -> URLRequest {
        guard let url = URL(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw ArtworkError("Enter a valid API base URL, including /v1 where required.") }
        var request = URLRequest(url: url.appendingPathComponent(path), timeoutInterval: 600)
        let env = ProcessInfo.processInfo.environment
        let token = !key.isEmpty ? key : configuration.provider == .gateway
            ? (env["AI_GATEWAY_API_KEY"] ?? env["VERCEL_OIDC_TOKEN"] ?? "") : (env["OPENAI_API_KEY"] ?? "")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func models() async throws -> [ArtworkModel] {
        var request = try request("models"); request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { throw ArtworkError("The endpoint returned an invalid model catalog.") }
        var seen = Set<String>()
        return rows.compactMap(ArtworkModel.parse).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }

    func generate(prompt: String, transparent: Bool, reference: Data?) async throws -> Data {
        guard let model = configuration.model else { throw ArtworkError("Choose an image model in Artwork Settings first.") }
        if configuration.provider == .gateway, !model.chat {
            return try await gatewayImage(model: model, prompt: prompt, transparent: transparent, reference: reference)
        }
        var body: [String: Any] = ["model": model.id]
        let native = model.nativeTransparency
        let instruction = Self.prompt(prompt, transparent: transparent, native: native)
        var request: URLRequest
        if model.chat {
            request = try self.request("chat/completions")
            var content: [[String: Any]] = [["type": "text", "text": instruction]]
            if let reference { content.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + reference.base64EncodedString()]]) }
            body["messages"] = [["role": "user", "content": content]]
            body["modalities"] = ["image", "text"]
            body["stream"] = false
        } else {
            request = try self.request(reference == nil ? "images/generations" : "images/edits")
            body["prompt"] = instruction; body["n"] = 1
            if native {
                body["background"] = transparent ? "transparent" : "opaque"
                body["output_format"] = "png"
            } else { body["response_format"] = "b64_json" }
        }
        request.httpMethod = "POST"
        if let reference, !model.chat {
            let boundary = "Artwork-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var multipart = Data()
            for (name, value) in body.sorted(by: { $0.key < $1.key }) {
                multipart.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            multipart.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"reference.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
            multipart.append(reference); multipart.append(Data("\r\n--\(boundary)--\r\n".utf8)); request.httpBody = multipart
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let item = (object["data"] as? [[String: Any]])?.first {
            if let b64 = item["b64_json"] as? String, let result = Data(base64Encoded: b64) { return result }
            if let url = item["url"] as? String { return try await image(at: url) }
        }
        let message = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        for item in (message["images"] as? [[String: Any]] ?? []) + (message["content"] as? [[String: Any]] ?? []) {
            if let url = (item["image_url"] as? [String: Any])?["url"] as? String { return try await image(at: url) }
        }
        throw ArtworkError("The image provider returned no image. Check the selected model's generation support.")
    }

    /// Gateway image-only models use the AI SDK image protocol, not OpenAI's /images endpoint.
    private func gatewayImage(model: ArtworkModel, prompt: String, transparent: Bool, reference: Data?) async throws -> Data {
        var request = try self.request("models")
        request.url = URL(string: "https://ai-gateway.vercel.sh/v4/ai/image-model")!
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("4", forHTTPHeaderField: "ai-image-model-specification-version")
        request.setValue(model.id, forHTTPHeaderField: "ai-model-id")
        request.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
        let hasAPIKey = !key.isEmpty || !(ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"] ?? "").isEmpty
        request.setValue(hasAPIKey ? "api-key" : "oidc", forHTTPHeaderField: "ai-gateway-auth-method")
        var body: [String: Any] = ["prompt": Self.prompt(prompt, transparent: transparent, native: model.nativeTransparency), "n": 1, "size": "1024x1024"]
        if model.nativeTransparency {
            body["providerOptions"] = ["openai": ["background": transparent ? "transparent" : "opaque", "outputFormat": "png"]]
        }
        if let reference {
            body["files"] = [["type": "file", "mediaType": "image/png", "data": reference.base64EncodedString()]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let encoded = (object?["images"] as? [String])?.first,
              let image = Data(base64Encoded: encoded), image.count <= 20_000_000 else {
            throw ArtworkError("AI Gateway returned no supported image under 20 MB.")
        }
        return image
    }

    static func prompt(_ prompt: String, transparent: Bool, native: Bool) -> String {
        guard transparent else { return prompt + "\nRender an opaque, full-bleed background plate." }
        return prompt + (native ? "\nUse a genuinely transparent background with alpha. No checkerboard or baked-in shadow."
            : "\nIsolate the subject against a perfectly flat pure #00FF00 green-screen background. No green on the subject, no gradient, shadow, glow or checkerboard. Preserve fine edges; the app will key out green.")
    }

    private func image(at value: String) async throws -> Data {
        if value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])) { return data }
        guard let url = URL(string: value), url.scheme == "https" else { throw ArtworkError("The provider returned an invalid image URL.") }
        // Signed provider downloads never receive the user's API credential.
        let (data, response) = try await session.data(from: url); try Self.check(response, data)
        return data
    }
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Keep upstream bodies (which can contain credentials or signed URLs) out of tool logs.
            throw ArtworkError("Image provider request failed (HTTP \(status)). Check credentials, model access and endpoint configuration.")
        }
        guard data.count <= 30_000_000 else { throw ArtworkError("The image provider response exceeds 30 MB.") }
    }
}

struct ArtworkError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }

/// Convert every result to PNG. Chroma key includes enclosed gaps, softens edges and suppresses green spill.
enum ArtworkPNG {
    static func encode(_ data: Data, keyGreen: Bool, requireAlpha: Bool) throws -> Data {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 20_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ArtworkError("The provider did not return a supported still image under 20 MB / 20 megapixels.") }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { throw ArtworkError("Could not decode image pixels.") }
        if keyGreen { key(&pixels, width: width, height: height) }
        if requireAlpha {
            let clear = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] < 32 }.count
            guard clear > max(1, width * height / 1000), clear < width * height * 99 / 100 else {
                throw ArtworkError("The cutout has no usable transparency. Regenerate it with a clean transparent or pure green background.")
            }
        }
        let output = NSMutableData()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw ArtworkError("Could not encode the scene PNG.") }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtworkError("Could not save the scene PNG.") }
        return output as Data
    }

    static func key(_ pixels: inout [UInt8], width: Int, height: Int) {
        for i in 0..<(width * height) {
            let p = i * 4
            let r = Double(pixels[p]), g = Double(pixels[p + 1]), b = Double(pixels[p + 2])
            let dominance = g - max(r, b)
            guard g > 65, dominance > 25 else { continue }
            let blend = min(1, max(0, (dominance - 25) / 100))
            let keep = 1 - blend * blend * (3 - 2 * blend)
            pixels[p] = UInt8(r * keep)
            pixels[p + 1] = UInt8(min(g, max(r, b)) * keep)
            pixels[p + 2] = UInt8(b * keep)
            pixels[p + 3] = UInt8(Double(pixels[p + 3]) * keep)
        }
    }
}
