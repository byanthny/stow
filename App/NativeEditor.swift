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
        let font =
            appearance.editorFontName.flatMap { NSFont(name: $0, size: appearance.editorFontSize) }
            ?? .systemFont(ofSize: appearance.editorFontSize)
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeEditor
        var focusedRequestID: UUID?
        var appliedAppearance: AppearanceSettings?
        init(_ parent: NativeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
        }
    }
}
