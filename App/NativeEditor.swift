import AppKit
import StowCore
import SwiftUI

extension NSAttributedString.Key {
    /// A web link in a note's text, opened with ⌘-click or the context menu.
    static let noteLink = NSAttributedString.Key("StowNoteLink")
}

struct NativeEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    var shouldFocus = false
    var focusRequestID: UUID
    var accessibilityID = "note.source"
    var appearance: AppearanceSettings
    /// When set, the editor fits its text within this range and scrolls past it; otherwise it fills its space.
    var fitsText: ClosedRange<CGFloat>?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoteScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        let editor = NoteTextView()
        editor.isEditable = isEnabled
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 4, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier(accessibilityID)
        editor.setAccessibilityLabel("Note Markdown source")
        editor.string = text
        Self.applyAppearance(appearance, to: editor)
        context.coordinator.appliedAppearance = appearance
        Self.styleMarkdown(in: editor, appearance: appearance)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = isEnabled
        context.coordinator.parent = self
        let sourceChanged = editor.string != text
        if sourceChanged {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if sourceChanged || context.coordinator.appliedAppearance != appearance {
            Self.applyAppearance(appearance, to: editor)
            context.coordinator.appliedAppearance = appearance
            Self.styleMarkdown(in: editor, appearance: appearance)
        }
        if shouldFocus && context.coordinator.focusedRequestID != focusRequestID {
            let request = focusRequestID
            DispatchQueue.main.async {
                guard context.coordinator.parent.shouldFocus,
                    context.coordinator.parent.focusRequestID == request,
                    let window = editor.window
                else { return }
                window.makeFirstResponder(editor)
                context.coordinator.focusedRequestID = request
            }
        }

    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let fitsText, let editor = scroll.documentView as? NSTextView else { return nil }
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? scroll.frame.width
        guard width > 0 else { return nil }
        let height = Self.textHeight(of: editor, width: width, limit: fitsText.upperBound)
        return CGSize(width: width, height: min(max(height, fitsText.lowerBound), fitsText.upperBound))
    }

    /// The height `editor` needs for its text at `width`, measured on a copy and no further than `limit`.
    static func textHeight(of editor: NSTextView, width: CGFloat, limit: CGFloat) -> CGFloat {
        guard let source = editor.textStorage else { return 0 }
        let inset = editor.textContainerInset
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: max(width - inset.width * 2, 1), height: 0))
        container.lineFragmentPadding = editor.textContainer?.lineFragmentPadding ?? 5
        layout.textContainer = container
        content.attributedString = NSAttributedString(attributedString: source)
        var height: CGFloat = 0
        layout.enumerateTextLayoutFragments(
            from: layout.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            height = fragment.layoutFragmentFrame.maxY
            return height < limit
        }
        return height.rounded(.up) + inset.height * 2
    }

    static func applyAppearance(_ appearance: AppearanceSettings, to editor: NSTextView) {
        let font = editorFont(appearance)
        let textColor = NSColor(Color(stowHex: appearance.colors.text))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = appearance.editorLineHeight
        editor.font = font
        editor.textColor = textColor
        editor.insertionPointColor = textColor
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph]
        editor.textStorage?.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
    }

    /// Shows the note's Markdown as it reads, leaving its text, and so its Markdown file, as typed.
    static func styleMarkdown(in editor: NSTextView, appearance: AppearanceSettings) {
        // Restyling while an input method is composing would disturb it; the composed text arrives as an edit later.
        guard let storage = editor.textStorage, !editor.hasMarkedText() else { return }
        let base = editorFont(appearance)
        let text = NSColor(Color(stowHex: appearance.colors.text))
        let muted = NSColor(Color(stowHex: appearance.colors.muted))
        let whole = NSRange(location: 0, length: storage.length)
        let spans = MarkdownStyle.spans(in: storage.string)
        let title = spans.first { $0.kind == .title }?.range
        storage.beginEditing()
        storage.addAttributes([.font: base, .foregroundColor: text], range: whole)
        for key in styleKeys { storage.removeAttribute(key, range: whole) }
        // Line fonts first, then emphasis on top of them, and code last so it wins.
        for span in spans {
            switch span.kind {
            case .title:
                storage.addAttribute(.font, value: scaled(base, by: titleScale, weight: .semibold), range: span.range)
            case .heading(let level):
                let heading = headingScales[min(level, headingScales.count) - 1]
                let scale = max(heading, span.range == title ? titleScale : 1)
                storage.addAttribute(.font, value: scaled(base, by: scale, weight: .bold), range: span.range)
            default: break
            }
        }
        for span in spans {
            switch span.kind {
            case .bold: addTrait(.boldFontMask, in: storage, range: span.range)
            case .italic: addTrait(.italicFontMask, in: storage, range: span.range)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .quote, .marker: storage.addAttribute(.foregroundColor, value: muted, range: span.range)
            case .link(let url):
                storage.addAttributes(
                    [
                        .underlineStyle: NSUnderlineStyle.single.rawValue, .noteLink: url,
                        .toolTip: "⌘-click to open \(url.absoluteString)",
                    ], range: span.range)
            case .title, .heading, .code: break
            }
        }
        let code = NSFont.monospacedSystemFont(ofSize: CGFloat(appearance.editorFontSize) * 0.94, weight: .regular)
        let background = text.withAlphaComponent(0.08)
        for span in spans where span.kind == .code {
            storage.addAttributes([.font: code, .backgroundColor: background], range: span.range)
        }
        storage.endEditing()
        // Typing starts as plain text, and the next pass styles it for where it lands.
        editor.typingAttributes[.font] = base
        editor.typingAttributes[.foregroundColor] = text
        for key in styleKeys { editor.typingAttributes[key] = nil }
    }

    /// Attributes the styling pass sets on parts of the text, cleared before each pass.
    private static let styleKeys: [NSAttributedString.Key] = [
        .backgroundColor, .strikethroughStyle, .underlineStyle, .obliqueness, .strokeWidth, .noteLink, .toolTip,
    ]
    private static let titleScale: CGFloat = 1.3
    private static let headingScales: [CGFloat] = [1.3, 1.18, 1.08, 1, 1, 1]

    /// `base` at `scale` times its size. The system font takes `weight`; other fonts take their bold face.
    private static func scaled(_ base: NSFont, by scale: CGFloat, weight: NSFont.Weight) -> NSFont {
        let size = (base.pointSize * scale).rounded()
        if base.familyName == NSFont.systemFont(ofSize: size).familyName {
            return .systemFont(ofSize: size, weight: weight)
        }
        let manager = NSFontManager.shared
        return manager.convert(manager.convert(base, toSize: size), toHaveTrait: .boldFontMask)
    }

    /// Makes every font in `range` bold or italic. A font without that face gets a slant or a heavier stroke.
    private static func addTrait(_ trait: NSFontTraitMask, in storage: NSTextStorage, range: NSRange) {
        let manager = NSFontManager.shared
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            let converted = manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: run)
            guard !manager.traits(of: converted).contains(trait) else { return }
            if trait == .italicFontMask {
                storage.addAttribute(.obliqueness, value: 0.2, range: run)
            } else {
                storage.addAttribute(.strokeWidth, value: -3.0, range: run)
            }
        }
    }

    private static func editorFont(_ appearance: AppearanceSettings) -> NSFont {
        appearance.editorFontName.flatMap { NSFont(name: $0, size: appearance.editorFontSize) }
            ?? .systemFont(ofSize: appearance.editorFontSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeEditor
        var focusedRequestID: UUID?
        var appliedAppearance: AppearanceSettings?
        init(_ parent: NativeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            NativeEditor.styleMarkdown(in: editor, appearance: parent.appearance)
            // A note that fits its text measures itself again.
            if parent.fitsText != nil { editor.enclosingScrollView?.invalidateIntrinsicContentSize() }
            if parent.text != editor.string { parent.text = editor.string }
        }
    }
}

/// A note's text. ⌘-click on a link, or Open Link in its context menu, opens it; a plain click edits as usual.
final class NoteTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = link(at: event) {
            AppStore.openLink(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let url = link(at: event) else { return menu }
        let open = NSMenuItem(title: "Open Link", action: #selector(openLinkItem(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = url
        let result = menu ?? NSMenu()
        result.insertItem(open, at: 0)
        result.insertItem(.separator(), at: 1)
        return result
    }

    @objc private func openLinkItem(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { AppStore.openLink(url) }
    }

    private func link(at event: NSEvent) -> URL? {
        link(atInsertionPoint: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    /// The link on either side of an insertion point, so a click anywhere on a link's characters finds it.
    func link(atInsertionPoint index: Int) -> URL? {
        guard let storage = textStorage else { return nil }
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            if let url = storage.attribute(.noteLink, at: candidate, effectiveRange: nil) as? URL { return url }
        }
        return nil
    }
}

/// A note editor's scroll view; when the note grows as you type, the board scrolls to keep the cursor in view.
final class NoteScrollView: NSScrollView {
    override func setFrameSize(_ newSize: NSSize) {
        let grew = newSize.height > frame.height + 0.5
        super.setFrameSize(newSize)
        guard grew, let editor = documentView, window?.firstResponder === editor else { return }
        // The board finishes laying out the taller note first.
        DispatchQueue.main.async { [weak self] in self?.revealCursor() }
    }

    func revealCursor() {
        guard let editor = documentView as? NSTextView, window?.firstResponder === editor,
            let cursor = Self.cursorFrame(in: editor)
        else { return }
        // Scrolls the enclosing board, if there is one, with a little room around the line.
        let frame = convert(cursor, from: editor)
        scrollToVisible(NSRect(x: frame.minX, y: frame.minY, width: 1, height: frame.height).insetBy(dx: 0, dy: -8))
    }

    /// The insertion point's frame in `editor`'s coordinates, from TextKit 2's layout.
    static func cursorFrame(in editor: NSTextView) -> NSRect? {
        guard let layout = editor.textLayoutManager, let content = layout.textContentManager,
            let location = content.location(
                content.documentRange.location, offsetBy: editor.selectedRange().location)
        else { return nil }
        let cursor = NSTextRange(location: location)
        layout.ensureLayout(for: cursor)
        var frame: NSRect?
        layout.enumerateTextSegments(in: cursor, type: .selection, options: [.rangeNotRequired]) { _, segment, _, _ in
            frame = segment
            return false
        }
        let origin = editor.textContainerOrigin
        return frame.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }
}
