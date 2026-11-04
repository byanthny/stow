import AppKit
import MarkdownUI
import SwiftUI

/// The renderer dependency and its network policy are confined to this component.
struct MarkdownPreview: View {
    let source: String
    @Environment(\.stowTheme) private var theme
    var body: some View {
        let fontSize = theme.settings.editorFontSize
        let fontFamily = markdownFontFamily
        let textColor = theme.color(.text)
        let imageProvider = OfflineBlockImages(font: theme.font(size: 11), foregroundColor: theme.color(.muted))
        Markdown(source)
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontSize(fontSize)
                FontFamily(fontFamily)
                ForegroundColor(textColor)
            }
            .markdownImageProvider(imageProvider)
            .markdownInlineImageProvider(OfflineInlineImages())
            .textSelection(.enabled)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
                    AppStore.openLink(url)
                    return .handled
                }
            )
            .accessibilityIdentifier("note.preview")
    }

    private var markdownFontFamily: FontProperties.Family {
        if let name = theme.settings.editorFontName, NSFont(name: name, size: 13) != nil {
            return .custom(name)
        }
        return .system()
    }
}

private struct OfflineBlockImages: ImageProvider {
    let font: Font
    let foregroundColor: Color

    func makeImage(url: URL?) -> some View {
        Label("Image hidden", systemImage: "photo")
            .font(font).foregroundStyle(foregroundColor).padding(.vertical, 4)
    }
}

private struct OfflineInlineImages: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}
