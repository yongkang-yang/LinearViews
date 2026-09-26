// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The block structure of a Markdown document. SwiftUI renders inline
/// Markdown (bold, code, links) on its own but not headings, lists, fences or
/// rules, so those are split out here and each block's text is left for the
/// view to render inline.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, depth: Int, text: String)
    case code(String)
    case quote(String)
    /// A pipe table, kept as its source lines and shown in a fixed-width font.
    case table(String)
    case rule

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))) }
            paragraph = []
            quote = []
            table = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if let fence = Self.fence(trimmed) {
                flush()
                var body: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if candidate.hasPrefix(fence), candidate.allSatisfy({ $0 == fence.first }) { break }
                    body.append(lines[index - 1])
                }
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let heading = Self.heading(trimmed) {
                flush()
                blocks.append(heading)
                continue
            }
            if Self.isRule(trimmed) {
                flush()
                blocks.append(.rule)
                continue
            }
            if let item = Self.listItem(line) {
                flush()
                blocks.append(item)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !table.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                table.append(trimmed)
                continue
            }
            // A line indented under a list item continues it.
            if paragraph.isEmpty, quote.isEmpty, table.isEmpty, line.hasPrefix("  "),
               case let .listItem(marker, depth, text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: text + "\n" + trimmed)
                continue
            }
            if !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }

    private static func fence(_ line: String) -> String? {
        for mark in ["```", "~~~"] where line.hasPrefix(mark) {
            return String(line.prefix(while: { $0 == mark.first }))
        }
        return nil
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes ("## Title ##") are decoration.
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        var marker: String
        if let first = rest.first, "-*+".contains(first) {
            marker = "•"
            guard rest.dropFirst().first == " " else { return nil }
            var text = String(rest.dropFirst(2))
            // Task list boxes read better as boxes than as brackets.
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text.removeFirst(4) }
            return .listItem(marker: marker, depth: indent / 2, text: text)
        }
        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let punctuation = after.first, punctuation == "." || punctuation == ")",
              after.dropFirst().first == " " else { return nil }
        marker = digits + "."
        return .listItem(marker: marker, depth: indent / 2, text: String(after.dropFirst(2)))
    }
}
