import AppKit
import StowCore
import SwiftUI

struct NativeEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    var shouldFocus = false
    var focusRequestID: UUID
    var accessibilityID = "note.source"
    var appearance: AppearanceSettings

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = NSTextView()
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
        context.coordinator.showsCode = Self.styleCode(in: editor, appearance: appearance, wasShowingCode: false)
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
            context.coordinator.showsCode = Self.styleCode(in: editor, appearance: appearance, wasShowingCode: true)
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

    /// Shows code in a fixed-width font on a faint background. Only how the text looks changes: the note's text,
    /// and so its Markdown file, stay as typed. Returns whether any code shows, so notes without code skip the work.
    static func styleCode(in editor: NSTextView, appearance: AppearanceSettings, wasShowingCode: Bool) -> Bool {
        // Restyling while an input method is composing would disturb it; the composed text arrives as an edit later.
        guard let storage = editor.textStorage, !editor.hasMarkedText() else { return wasShowingCode }
        let spans = MarkdownCode.spans(in: storage.string)
        guard !spans.isEmpty || wasShowingCode else { return false }
        let base = editorFont(appearance)
        let code = NSFont.monospacedSystemFont(ofSize: CGFloat(appearance.editorFontSize) * 0.94, weight: .regular)
        let background = NSColor(Color(stowHex: appearance.colors.text)).withAlphaComponent(0.08)
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.font, value: base, range: whole)
        storage.removeAttribute(.backgroundColor, range: whole)
        for span in spans { storage.addAttributes([.font: code, .backgroundColor: background], range: span.range) }
        storage.endEditing()
        // Typing next to code starts as plain text, and the next pass styles it if it lands inside code.
        editor.typingAttributes[.font] = base
        editor.typingAttributes[.backgroundColor] = nil
        return !spans.isEmpty
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
        var showsCode = false
        init(_ parent: NativeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            showsCode = NativeEditor.styleCode(in: editor, appearance: parent.appearance, wasShowingCode: showsCode)
            if parent.text != editor.string { parent.text = editor.string }
        }
    }
}
