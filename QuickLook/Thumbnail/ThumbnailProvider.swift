import Cocoa
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let song = try PreviewSong.read(request.fileURL)
            let title = request.fileURL.deletingPathExtension().lastPathComponent
            let size = NSSize(width: min(512, request.maximumSize.width), height: min(640, request.maximumSize.height))
            handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
                let scale = min(size.width / 512, size.height / 640)
                let transform = NSAffineTransform()
                transform.scale(by: scale)
                transform.concat()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 512, height: 640), xRadius: 24, yRadius: 24).fill()
                NSColor.systemIndigo.setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 510, width: 512, height: 130)).fill()
                func draw(_ text: String, _ rect: NSRect, _ font: NSFont, _ color: NSColor) {
                    (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color])
                }
                draw("LYRIC STUDIO", NSRect(x: 30, y: 588, width: 450, height: 24), .boldSystemFont(ofSize: 16), .white)
                draw(title, NSRect(x: 30, y: 520, width: 450, height: 62), .boldSystemFont(ofSize: 26), .white)
                var y: CGFloat = 436
                for line in song.lines.prefix(4) {
                    draw(line.original, NSRect(x: 30, y: y, width: 452, height: 52), .boldSystemFont(ofSize: 20), .black)
                    if let translated = line.translated, !translated.isEmpty {
                        draw(translated, NSRect(x: 30, y: y - 44, width: 452, height: 42), .systemFont(ofSize: 18), .systemIndigo)
                    }
                    y -= 96
                }
                draw(song.lines.isEmpty ? "No lyrics yet" : "\(song.lines.count) lines · \(song.target ?? "Translation")", NSRect(x: 30, y: 24, width: 450, height: 24), .systemFont(ofSize: 15), .darkGray)
                return true
            }), nil)
        } catch { handler(nil, error) }
    }
}
