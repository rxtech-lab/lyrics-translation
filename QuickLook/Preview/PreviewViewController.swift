import Cocoa
import QuickLookUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 28, height: 24)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        view = scroll
        preferredContentSize = NSSize(width: 760, height: 640)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let song = try PreviewSong.read(url)
        loadViewIfNeeded()
        let output = NSMutableAttributedString()
        func append(_ string: String, size: CGFloat, color: NSColor, bold: Bool = false) {
            output.append(NSAttributedString(string: string + "\n", attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color
            ]))
        }
        append(url.deletingPathExtension().lastPathComponent, size: 28, color: .labelColor, bold: true)
        append("LYRIC STUDIO · \(song.target ?? "Translation")\n", size: 12, color: .secondaryLabelColor)
        if song.lines.isEmpty { append("No lyrics yet", size: 17, color: .secondaryLabelColor) }
        for line in song.lines.prefix(2000) {
            let label = [line.section, line.speaker].compactMap { $0 }.joined(separator: " · ")
            if !label.isEmpty { append(label, size: 12, color: .secondaryLabelColor) }
            append(line.original, size: 17, color: .labelColor, bold: true)
            if let translated = line.translated, !translated.isEmpty {
                append(translated, size: 17, color: .systemIndigo)
            }
            append("", size: 10, color: .labelColor)
        }
        if song.lines.count > 2000 { append("Open in Lyric Studio to read all lines.", size: 13, color: .secondaryLabelColor) }
        let scroll = view as! NSScrollView
        let text = scroll.documentView as! NSTextView
        text.frame.size.width = scroll.contentSize.width
        text.textStorage?.setAttributedString(output)
    }
}
