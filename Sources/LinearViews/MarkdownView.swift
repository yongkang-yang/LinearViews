// SPDX-License-Identifier: GPL-3.0-or-later
import LinearViewsKit
import SwiftUI

/// Renders Markdown the way the model writes it: headings, lists, fences and
/// rules as blocks, bold, italics, code and links inline. Text is selectable.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    var fontSize: CGFloat = 13

    init(_ source: String, fontSize: CGFloat = 13) {
        self.blocks = MarkdownBlock.parse(source)
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(.system(size: fontSize + max(0, CGFloat(4 - level) * 1.5), weight: .semibold))
                .padding(.top, 4)
        case let .paragraph(text):
            Text(inline(text))
                .font(.system(size: fontSize))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case let .listItem(marker, depth, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: fontSize).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12, alignment: .trailing)
                Text(inline(text))
                    .font(.system(size: fontSize))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case let .code(text), let .table(text):
            Text(text)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case let .quote(text):
            Text(inline(text))
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2)
                }
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
