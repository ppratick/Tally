import SwiftUI

/// Render model answers as native paragraphs, lists, and tables while retaining transaction links.
struct ChatAnswerText: View, Equatable {
    let text: String
    private enum Block {
        case paragraph(String), heading(String), bullet(String, String), quote(String), code(String), table([[String]])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let value): inline(value).font(.body).lineSpacing(5).textSelection(.enabled)
        case .heading(let value): inline(value).font(.headline).padding(.top, 4).textSelection(.enabled)
        case .bullet(let marker, let value):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .leading)
                inline(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.font(.body).lineSpacing(4)
        case .quote(let value):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Color.tallyAccent.opacity(0.4)).frame(width: 3)
                inline(value).foregroundStyle(.secondary).textSelection(.enabled)
            }.fixedSize(horizontal: false, vertical: true)
        case .code(let value):
            ScrollView(.horizontal) { Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(14) }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell).font(index == 0 ? .subheadline.weight(.semibold) : .subheadline)
                                    .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                            }
                        }
                        if index == 0 { Divider().gridCellColumns(rows.map(\.count).max() ?? 1) }
                    }
                }.padding(16)
            }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private var blocks: [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = [], paragraph: [String] = [], index = 0
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func cells(_ line: String) -> [String] {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
            return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); index += 1; continue }
            if line.hasPrefix("```") {
                flush(); index += 1; var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                result.append(.code(code.joined(separator: "\n"))); index += 1; continue
            }
            if line.contains("|"), index + 1 < lines.count {
                let separator = cells(lines[index + 1])
                if !separator.isEmpty, separator.allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) {
                    flush(); var rows = [cells(line)]; index += 2
                    while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        rows.append(cells(lines[index])); index += 1
                    }
                    result.append(.table(rows)); continue
                }
            }
            if let prefix = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flush(); result.append(.heading(String(line[prefix.upperBound...])))
            } else if let prefix = line.range(of: "^([-*+]\\s+|[0-9]+[.)]\\s+)", options: .regularExpression) {
                flush(); let marker = String(line[prefix]).trimmingCharacters(in: .whitespaces)
                result.append(.bullet(["-", "*", "+"].contains(marker) ? "•" : marker, String(line[prefix.upperBound...])))
            } else if line.hasPrefix("> ") {
                flush(); result.append(.quote(String(line.dropFirst(2))))
            } else if line == "---" || line == "***" { flush() }
            else { paragraph.append(line) }
            index += 1
        }
        flush(); return result
    }
}
