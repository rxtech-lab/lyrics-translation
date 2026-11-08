import Cocoa
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let song = try PreviewSong.read(request.fileURL)
            let title = request.fileURL.deletingPathExtension().lastPathComponent
            // Preserve the cover's aspect ratio, including in small Finder icons.
            let scale = min(request.maximumSize.width / 512, request.maximumSize.height / 640)
            let size = NSSize(width: 512 * scale, height: 640 * scale)
            handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
                LyricCover.draw(song: song, title: title, scale: scale)
                return true
            }), nil)
        } catch { handler(nil, error) }
    }
}

/// A compact cover, rather than a miniature page of unreadable document text.
enum LyricCover {
    static func draw(song: PreviewSong, title: String, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        let ink = NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.24, alpha: 1)
        let accent = NSColor(calibratedRed: 0.38, green: 0.29, blue: 0.80, alpha: 1)
        let cover = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 512, height: 640), xRadius: 32, yRadius: 32)
        cover.addClip()
        NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.91, alpha: 1).setFill()
        cover.fill()
        accent.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 464, width: 512, height: 176)).fill()
        // A simple musical motif stays recognizable at Finder icon sizes.
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: 340, y: 448, width: 220, height: 220)).fill()
        text("♫", in: NSRect(x: 365, y: 488, width: 112, height: 120), size: 90, color: .white)
        text("LYRIC\nSTUDIO", in: NSRect(x: 36, y: 500, width: 300, height: 104), size: 38, color: .white, weight: .bold)
        text(title.isEmpty ? "Untitled song" : title,
             in: NSRect(x: 36, y: 306, width: 440, height: 130), size: 42, color: ink, weight: .bold)
        accent.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: NSRect(x: 36, y: 282, width: 64, height: 4)).fill()
        if let line = song.lines.first(where: { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            text(line.original, in: NSRect(x: 36, y: 183, width: 440, height: 76), size: 26, color: ink, weight: .medium)
            if let translated = line.translated, !translated.isEmpty {
                text(translated, in: NSRect(x: 36, y: 98, width: 440, height: 72), size: 24, color: accent)
            }
        } else {
            text("Your next song starts here", in: NSRect(x: 36, y: 183, width: 440, height: 76), size: 26, color: accent)
        }
        text("\(song.lines.count) lines · \(song.target ?? "Lyrics")",
             in: NSRect(x: 36, y: 30, width: 440, height: 32), size: 20, color: ink.withAlphaComponent(0.65), weight: .medium)
    }

    private static func text(_ value: String, in rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}
