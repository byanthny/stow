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
    /// Told when the text gains or loses focus.
    var onEditingChange: ((Bool) -> Void)?

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
        editor.onFocusChange = { [weak coordinator = context.coordinator, weak editor] focused in
            guard let coordinator, let editor else { return }
            coordinator.editingChanged(focused, in: editor)
        }
        editor.setAccessibilityIdentifier(accessibilityID)
        editor.setAccessibilityLabel("Note Markdown source")
        editor.string = text
        Self.applyAppearance(appearance, to: editor)
        context.coordinator.appliedAppearance = appearance
        context.coordinator.watchEdits(of: editor)
        context.coordinator.restyle(editor, everything: true)
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
            context.coordinator.restyle(editor, everything: true)
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
    /// Restyles only `range`, whole lines, when given, using `spans` parsed from the whole text.
    static func styleMarkdown(
        in editor: NSTextView, appearance: AppearanceSettings, spans: [MarkdownStyle.Span]? = nil,
        range: NSRange? = nil
    ) {
        // Restyling while an input method is composing would disturb it; the composed text arrives as an edit later.
        guard let storage = editor.textStorage, !editor.hasMarkedText() else { return }
        let base = editorFont(appearance)
        let text = NSColor(Color(stowHex: appearance.colors.text))
        let muted = NSColor(Color(stowHex: appearance.colors.muted))
        let whole = range ?? NSRange(location: 0, length: storage.length)
        let parsed = spans ?? MarkdownStyle.spans(in: storage.string)
        let title = parsed.first { $0.kind == .title }?.range
        let spans = parsed.compactMap { span -> MarkdownStyle.Span? in
            let visible = NSIntersectionRange(span.range, whole)
            return visible.length > 0 ? MarkdownStyle.Span(kind: span.kind, range: visible) : nil
        }
        storage.beginEditing()
        storage.addAttributes([.font: base, .foregroundColor: text], range: whole)
        for key in styleKeys { storage.removeAttribute(key, range: whole) }
        // Line fonts, then emphasis, then code on top.
        for span in spans {
            switch span.kind {
            case .title:
                storage.addAttribute(.font, value: scaled(base, by: titleScale, weight: .semibold), range: span.range)
            case .heading(let level):
                let heading = headingScales[min(level, headingScales.count) - 1]
                let scale = max(heading, span.range == title ? titleScale : 1)
                storage.addAttribute(.font, value: scaled(base, by: scale, weight: .bold), range: span.range)
            case .bold, .italic, .strikethrough, .code, .link, .quote, .marker: break
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
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopWatchingClicks()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeEditor
        var focusedRequestID: UUID?
        var appliedAppearance: AppearanceSettings?
        private var clickMonitor: Any?
        /// The board note being edited, while its window is watched.
        private weak var watchedEditor: NSTextView?
        /// A focus change the note hasn't heard about yet.
        private var reportedEditing: Bool?
        private var waitsForRelease = false
        /// The spans last styled, and the length of the text they were parsed from.
        private var styledSpans: [MarkdownStyle.Span] = []
        private var styledLength = 0
        /// Text edits since the last restyle.
        private var edits: [(range: NSRange, delta: Int)] = []
        init(_ parent: NativeEditor) { self.parent = parent }

        /// Any link the text view finds itself opens only if it's a web link.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { AppStore.openLink(url) }
            return true
        }

        func watchEdits(of editor: NSTextView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(textStorageEdited(_:)), name: NSTextStorage.didProcessEditingNotification,
                object: editor.textStorage)
        }

        @objc private func textStorageEdited(_ notification: Notification) {
            guard let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters)
            else { return }
            edits.append((storage.editedRange, storage.changeInLength))
        }

        /// Restyles the lines a single edit changed, or the whole text.
        func restyle(_ editor: NSTextView, everything: Bool) {
            guard let storage = editor.textStorage, !editor.hasMarkedText() else { return }
            let spans = MarkdownStyle.spans(in: storage.string)
            var range: NSRange?
            if !everything, edits.count == 1, let edit = edits.first, styledLength == storage.length - edit.delta {
                range = MarkdownStyle.changedRange(
                    from: styledSpans, to: spans, in: storage.string as NSString, edited: edit.range, delta: edit.delta)
            }
            NativeEditor.styleMarkdown(in: editor, appearance: parent.appearance, spans: spans, range: range)
            styledSpans = spans
            styledLength = storage.length
            edits = []
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            restyle(editor, everything: false)
            // A note that fits its text measures itself again.
            if parent.fitsText != nil { editor.enclosingScrollView?.invalidateIntrinsicContentSize() }
            if parent.text != editor.string { parent.text = editor.string }
        }

        /// While a board note is being edited, a click anywhere else in its window ends the editing.
        func editingChanged(_ editing: Bool, in editor: NSTextView) {
            if editing && parent.fitsText != nil { watchClicks(around: editor) } else { stopWatchingClicks() }
            report(editing)
        }

        /// With another window or app in front, a board note shrinks but keeps its cursor, and grows again on return.
        @objc private func windowKeyChanged(_ notification: Notification) {
            guard let editor = watchedEditor, editor.window?.firstResponder === editor else { return }
            report(notification.name == NSWindow.didBecomeKeyNotification)
        }

        private func report(_ editing: Bool) {
            reportedEditing = editing
            guard !waitsForRelease else { return }
            waitsForRelease = true
            // Reports after SwiftUI finishes updating its views.
            DispatchQueue.main.async { [weak self] in self?.reportWhenReleased() }
        }

        /// Tells the note once no mouse button is held, so nothing resizes under the pointer mid-click.
        private func reportWhenReleased() {
            // Polls until the mouse button is up.
            guard NSEvent.pressedMouseButtons == 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reportWhenReleased() }
                return
            }
            waitsForRelease = false
            guard let editing = reportedEditing else { return }
            reportedEditing = nil
            parent.onEditingChange?(editing)
        }

        private func watchClicks(around editor: NSTextView) {
            guard clickMonitor == nil else { return }
            watchedEditor = editor
            for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowKeyChanged(_:)), name: name, object: editor.window)
            }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak editor] event in
                if let editor, let window = editor.window, event.window === window, window.firstResponder === editor,
                    let scroll = editor.enclosingScrollView,
                    !scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
                {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func stopWatchingClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: nil)
            }
            watchedEditor = nil
        }
    }
}

/// A note's text. ⌘-click on a link, or Open Link in its context menu, opens it; a plain click edits as usual.
final class NoteTextView: NSTextView {
    /// Told when the text gains or loses focus.
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

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
        link(at: convert(event.locationInWindow, from: nil))
    }

    /// The link whose laid-out text lies under `point`, in this view's coordinates.
    func link(at point: NSPoint) -> URL? {
        guard let storage = textStorage else { return nil }
        let index = characterIndexForInsertion(at: point)
        let whole = NSRange(location: 0, length: storage.length)
        // The nearest insertion point lies on either side of the character under the point.
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            var range = NSRange()
            if let url = storage.attribute(.noteLink, at: candidate, longestEffectiveRange: &range, in: whole) as? URL,
                text(in: range, contains: point)
            {
                return url
            }
        }
        return nil
    }

    /// Whether `point`, in this view's coordinates, lies on the text of `range`, measured by TextKit 2's layout.
    private func text(in range: NSRange, contains point: NSPoint) -> Bool {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length),
            let textRange = NSTextRange(location: start, end: end)
        else { return false }
        let origin = textContainerOrigin
        let target = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        layout.ensureLayout(for: textRange)
        var contains = false
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            contains = segment.contains(target)
            return !contains
        }
        return contains
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
