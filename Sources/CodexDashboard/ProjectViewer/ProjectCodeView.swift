import AppKit
import SwiftUI

/// Native selectable, read-only text with horizontal scrolling and a line-number ruler.
struct ProjectCodeView: NSViewRepresentable {
    let text: String
    let path: String
    let semanticTokens: [ProjectSemanticToken]
    @Environment(\.colorScheme) private var colorScheme
    let jump: ProjectViewerModel.CodeJump?

    final class Coordinator {
        var text = ""
        var path = ""
        var jump: ProjectViewerModel.CodeJump?
        var tokens: [ProjectSemanticToken] = []
        var colorScheme: ColorScheme?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 16, height: 14)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = view.maxSize
        scroll.documentView = view
        scroll.verticalRulerView = ProjectLineRuler(textView: view, scrollView: scroll)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let state = context.coordinator
        if state.text != text || state.path != path || state.tokens != semanticTokens || state.colorScheme != colorScheme {
            let sameFile = state.path == path
            let origin = scroll.contentView.bounds.origin
            let selection = view.selectedRange()
            state.text = text
            state.path = path
            state.tokens = semanticTokens
            state.colorScheme = colorScheme
            let palette = ProjectCodePalette(dark: colorScheme == .dark)
            view.backgroundColor = palette.background
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: palette.foreground
            ])
            let range = NSRange(location: 0, length: (text as NSString).length)
            // A small lexical highlighter; display never interprets project content as HTML.
            let rules: [(String, NSColor)] = [
                (#"\b(?:import|from|export|default|class|struct|enum|protocol|extension|func|function|def|fn|fun|let|var|const|if|else|return|guard|for|while|switch|case|break|continue|async|await|throws|throw|try|catch|public|private|static|final|override|true|false|nil|null|None|self|this)\b"#, palette.keyword),
                (#"\b\d+(?:\.\d+)?\b"#, palette.number),
                (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, palette.string),
                (#"(?m)//[^\n]*|/\*[\s\S]*?\*/"#, palette.comment)
            ]
            for (pattern, color) in rules {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: text, range: range) {
                    attributed.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
            for token in semanticTokens {
                guard token.offset >= 0, token.length > 0, token.offset <= range.length,
                      token.length <= range.length - token.offset,
                      let color = palette.semanticColor(token, in: text as NSString) else { continue }
                attributed.addAttribute(.foregroundColor, value: color,
                                        range: NSRange(location: token.offset, length: token.length))
            }
            view.textStorage?.setAttributedString(attributed)
            if sameFile {
                if selection.location <= range.length && selection.length <= range.length - selection.location {
                    view.setSelectedRange(selection)
                }
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            else { view.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
            scroll.verticalRulerView?.needsDisplay = true
        }
        if let jump, jump != state.jump, !text.isEmpty {
            let line = jump.line
            let ns = text as NSString
            var location = 0
            for _ in 1..<max(1, line) {
                guard location < ns.length else { break }
                location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            }
            let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
            state.jump = jump
        } else if jump == nil { state.jump = nil }
    }
}

private struct ProjectCodePalette {
    let dark: Bool

    var background: NSColor { color(0xFFFFFF, 0x1E1F22) }
    var foreground: NSColor { color(0x080808, 0xBCBEC4) }
    var keyword: NSColor { color(0x0033B3, 0xCF8E6D) }
    var number: NSColor { color(0x1750EB, 0x2AACB8) }
    var string: NSColor { color(0x067D17, 0x6AAB73) }
    var comment: NSColor { color(0x676A70, 0x7A7E85) }

    func semanticColor(_ token: ProjectSemanticToken, in text: NSString) -> NSColor? {
        switch token.type {
        case "class", "enum", "interface", "struct", "type", "typeParameter", "namespace", "protocol":
            return color(0x000080, 0x56A8F5)
        case "function", "method":
            return color(0x00627A, 0xFFC66D)
        case "property", "enumMember":
            return color(0x871094, 0xC77DBB)
        case "parameter", "variable":
            let name = text.substring(with: NSRange(location: token.offset, length: token.length))
            let index = name.utf8.reduce(0) { ($0 * 31 + Int($1)) % 5 }
            return [
                color(0x9B3B6A, 0xDA9BBB), color(0x114D77, 0x75BBE5), color(0x805400, 0xD8B36C),
                color(0x005910, 0x86C593), color(0x9D3E38, 0xE5A098),
            ][index]
        case "keyword": return keyword
        case "string": return string
        case "comment": return comment
        case "number": return number
        default: return nil
        }
    }

    private func color(_ light: UInt32, _ darkValue: UInt32) -> NSColor {
        let value = dark ? darkValue : light
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

private final class ProjectLineRuler: NSRulerView {
    private weak var textView: NSTextView?
    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 58
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard layout.numberOfGlyphs > 0 else { return }
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        var index = glyphs.location
        let ns = textView.string as NSString
        let charStart = layout.characterIndexForGlyph(at: min(index, max(0, layout.numberOfGlyphs - 1)))
        var number = ns.substring(to: min(charStart, ns.length)).filter { $0 == "\n" }.count + 1
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        while index < NSMaxRange(glyphs), index < layout.numberOfGlyphs {
            var effective = NSRange()
            let line = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            let label = "\(number)" as NSString
            let y = line.minY + textView.textContainerInset.height - visible.minY
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 10, y: y), withAttributes: attributes)
            number += 1
            index = NSMaxRange(effective)
        }
    }
}
