import Foundation

/// The monthly spend cap read from the "Usage credits" block of the Claude CLI `/usage` panel, in whole currency units.
public struct ClaudeCLISpendCap: Equatable, Sendable {
    public let used: Double
    public let limit: Double
    public let currencyCode: String

    public init(used: Double, limit: Double, currencyCode: String) {
        self.used = used
        self.limit = limit
        self.currencyCode = currencyCode
    }
}

/// Reads the spend cap from rendered `/usage` text. The panel layout is not a contract, so this never throws and
/// returns nil on any mismatch; a nil result must leave the rest of the usage parse untouched.
enum ClaudeCLISpendCapParser {
    private static let headerKey = "usagecredits"
    private static let maxHeaderLength = 60
    private static let maxLinesAfterHeader = 6
    private static let maxAmount = 1_000_000_000_000.0

    // Only `$` is read as USD. A letter before it (`A$`, `CA$`) or a sign makes the amount something else.
    private static let amount = #"((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,4})?)"#
    private static let spendLine = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}\-+\x{2212}.,])\$\s*"# + amount + #"\s*/\s*\$\s*"# + amount + #"\s*spent\b"#,
        options: [.caseInsensitive])

    static func parse(_ renderedText: String) -> ClaudeCLISpendCap? {
        let lines = renderedText.components(separatedBy: .newlines)
        // Plain captures can hold several frames; the last block is the newest. If it has no valid spend line, an
        // older block is stale data, so do not fall back to it.
        guard let headerIndex = lines.indices.last(where: { self.isHeader(lines[$0]) }) else { return nil }
        let end = min(lines.endIndex, headerIndex + 1 + self.maxLinesAfterHeader)
        return lines[headerIndex..<end].lazy.compactMap { self.spendCap(in: $0) }.first
    }

    private static func isHeader(_ line: String) -> Bool {
        let key = String(line.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
        return key.hasPrefix(self.headerKey) && key.count <= self.maxHeaderLength
    }

    private static func spendCap(in line: String) -> ClaudeCLISpendCap? {
        guard let spendLine = self.spendLine else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = spendLine.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges == 3,
              let usedRange = Range(match.range(at: 1), in: line),
              let limitRange = Range(match.range(at: 2), in: line),
              let used = self.number(line[usedRange]),
              let limit = self.number(line[limitRange]),
              limit > 0
        else { return nil }
        return ClaudeCLISpendCap(used: used, limit: limit, currencyCode: "USD")
    }

    private static func number(_ text: Substring) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: "")),
              value.isFinite,
              (0...self.maxAmount).contains(value)
        else { return nil }
        return value
    }
}
