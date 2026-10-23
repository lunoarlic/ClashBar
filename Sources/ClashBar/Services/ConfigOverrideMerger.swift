import Foundation

/// Merges a user-maintained override file (Clash Verge style) into a selected Clash config.
///
/// Supported override syntax (top-level keys only):
/// - `+rules:` (or any `+<list-key>:` such as `+proxies:`) prepends the following list items
///   to the same key in the source config, so they take priority (e.g. `DIRECT` bypass rules).
/// - A plain top-level key such as `ipv6: false` replaces the same key in the source config.
/// - A plain top-level mapping block (e.g. a nested `dns:` section) replaces the whole block.
///
/// The merge is line-based on purpose: the project has no YAML dependency and the source
/// config must stay byte-identical outside the touched keys (subscriptions keep comments).
/// The merged result is validated downstream by `mihomo -t` before the core launches.
enum ConfigOverrideMerger {
    static let preferredFileName = "override.yaml"
    /// Lives in the config directory as a hidden file: config scans skip dotfiles, and a config
    /// inside `config/` makes the core resolve its working directory to the app-support root,
    /// where the GeoIP/GeoSite databases already are (mirrors `CoreService` behavior).
    static let runtimeMergedFileName = ".runtime-merged.yaml"

    static let reservedFileNames: Set<String> = ["override.yaml", "override.yml"]

    static func isReservedFileName(_ fileName: String) -> Bool {
        reservedFileNames.contains(fileName.lowercased())
    }

    struct Outcome: Equatable {
        let text: String
        let appliedKeys: [String]
    }

    private struct OverrideEntry {
        let key: String
        let isPrepend: Bool
        /// Value text following the colon on the key line, verbatim (may be empty).
        let inlineValue: String
        /// Block lines belonging to this entry, verbatim (list items, nested keys, comments).
        let blockLines: [String]
        /// Indent of the first non-blank block line, used to re-indent when prepending.
        let blockIndent: Int

        var isScalar: Bool {
            inlineValue.trimmedNonEmpty != nil && !blockLines.contains(where: { $0.trimmedNonEmpty != nil })
        }
    }

    /// Returns nil when the override carries no applicable top-level entries (no-op).
    static func mergedText(sourceText: String, overrideText: String) -> Outcome? {
        let overrideLines = Self.normalizedLines(from: overrideText)
        let entries = Self.parseOverrideEntries(from: overrideLines)
        guard !entries.isEmpty else { return nil }

        var sourceLines = Self.normalizedLines(from: sourceText)
        var appliedKeys: [String] = []

        for entry in entries {
            if Self.apply(entry: entry, to: &sourceLines) {
                appliedKeys.append(entry.isPrepend ? "+\((entry.key))" : entry.key)
            }
        }

        guard !appliedKeys.isEmpty else { return nil }

        var merged = sourceLines.joined(separator: "\n")
        if !merged.isEmpty {
            merged += "\n"
        }
        return Outcome(text: merged, appliedKeys: appliedKeys)
    }

    // MARK: - Override parsing

    private static func parseOverrideEntries(from lines: [String]) -> [OverrideEntry] {
        let topLevelIndent = Self.detectTopLevelIndent(in: lines)
        var entries: [OverrideEntry] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let indent = Self.leadingWhitespaceCount(of: line)
            let content = String(line.dropFirst(indent)).trimmed

            if content.isEmpty || content.hasPrefix("#") || indent > topLevelIndent {
                index += 1
                continue
            }

            guard let (key, isPrepend, inlineValue) = Self.parseKeyLine(content) else {
                index += 1
                continue
            }

            var blockLines: [String] = []
            var cursor = index + 1
            while cursor < lines.count {
                let candidate = lines[cursor]
                let candidateIndent = Self.leadingWhitespaceCount(of: candidate)
                let candidateContent = String(candidate.dropFirst(candidateIndent)).trimmed
                let isStructural = !candidateContent.isEmpty
                    && !candidateContent.hasPrefix("#")
                    && candidateIndent <= topLevelIndent
                if isStructural {
                    break
                }
                blockLines.append(candidate)
                cursor += 1
            }

            guard !isNoOpEntry(key: key, isPrepend: isPrepend, inlineValue: inlineValue, blockLines: blockLines)
            else {
                index = cursor
                continue
            }

            entries.append(OverrideEntry(
                key: key,
                isPrepend: isPrepend,
                inlineValue: inlineValue,
                blockLines: blockLines,
                blockIndent: Self.firstContentIndent(in: blockLines) ?? topLevelIndent + 2))
            index = cursor
        }

        return entries
    }

    private static func isNoOpEntry(
        key: String,
        isPrepend: Bool,
        inlineValue: String,
        blockLines: [String]) -> Bool
    {
        let hasBlockContent = blockLines.contains(where: { $0.trimmedNonEmpty != nil })
        if isPrepend {
            // `+key:` without list items (or with only comments) is a no-op.
            return !hasBlockContent || inlineValue.trimmedNonEmpty != nil
        }
        // Plain `key:` with neither a value nor a block is a no-op.
        return inlineValue.trimmedNonEmpty == nil && !hasBlockContent
    }

    private static func parseKeyLine(_ content: String) -> (key: String, isPrepend: Bool, inlineValue: String)? {
        guard let colonIndex = content.firstIndex(of: ":") else { return nil }

        var key = String(content[content.startIndex..<colonIndex]).trimmed
        guard !key.isEmpty else { return nil }

        var isPrepend = false
        if key.hasPrefix("+") {
            key.removeFirst()
            isPrepend = true
        }

        // YAML keys are plain words; reject quoted or spaced fragments.
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }

        let inlineValue = String(content[content.index(after: colonIndex)...])
        return (key, isPrepend, inlineValue)
    }

    private static func detectTopLevelIndent(in lines: [String]) -> Int {
        for line in lines {
            let indent = Self.leadingWhitespaceCount(of: line)
            let content = String(line.dropFirst(indent)).trimmed
            if !content.isEmpty, !content.hasPrefix("#") {
                return indent
            }
        }
        return 0
    }

    private static func firstContentIndent(in lines: [String]) -> Int? {
        for line in lines where line.trimmedNonEmpty != nil {
            return Self.leadingWhitespaceCount(of: line)
        }
        return nil
    }

    // MARK: - Source mutation

    private static func apply(entry: OverrideEntry, to sourceLines: inout [String]) -> Bool {
        if entry.isPrepend {
            return applyPrepend(entry: entry, to: &sourceLines)
        }
        if entry.isScalar {
            return applyScalarReplace(entry: entry, to: &sourceLines)
        }
        return applyBlockReplace(entry: entry, to: &sourceLines)
    }

    private static func applyPrepend(entry: OverrideEntry, to sourceLines: inout [String]) -> Bool {
        guard let keyIndex = Self.topLevelKeyLineIndex(of: entry.key, in: sourceLines) else {
            appendEntry(entry, to: &sourceLines)
            return true
        }

        let keyLine = sourceLines[keyIndex]
        let existingValue = Self.valueText(afterKey: entry.key, inLine: keyLine).trimmed
        let items = Self.shifted(entry.blockLines, toIndent: Self.listIndent(in: sourceLines, after: keyIndex))

        if existingValue == "[]" {
            sourceLines.replaceSubrange(keyIndex...keyIndex, with: ["\(entry.key):"] + items)
            return true
        }
        if existingValue.isEmpty {
            sourceLines.insert(contentsOf: items, at: keyIndex + 1)
            return true
        }

        // Unexpected inline value (e.g. `rules: [ ... ]` flow style): replace conservatively.
        sourceLines.replaceSubrange(keyIndex...keyIndex, with: ["\(entry.key):"] + items)
        return true
    }

    private static func applyScalarReplace(entry: OverrideEntry, to sourceLines: inout [String]) -> Bool {
        let replacement = "\(entry.key):\(entry.inlineValue)"
        if let keyIndex = Self.topLevelKeyLineIndex(of: entry.key, in: sourceLines) {
            sourceLines.replaceSubrange(keyIndex...keyIndex, with: [replacement])
        } else {
            appendLines([replacement], to: &sourceLines)
        }
        return true
    }

    private static func applyBlockReplace(entry: OverrideEntry, to sourceLines: inout [String]) -> Bool {
        let entryLines = Self.entryLines(entry)
        guard let keyIndex = Self.topLevelKeyLineIndex(of: entry.key, in: sourceLines) else {
            appendEntry(entry, to: &sourceLines)
            return true
        }

        var end = keyIndex + 1
        while end < sourceLines.count {
            let line = sourceLines[end]
            let indent = Self.leadingWhitespaceCount(of: line)
            let content = String(line.dropFirst(indent)).trimmed
            if !content.isEmpty, !content.hasPrefix("#"), indent == 0 {
                break
            }
            end += 1
        }

        sourceLines.replaceSubrange(keyIndex..<end, with: entryLines)
        return true
    }

    private static func appendEntry(_ entry: OverrideEntry, to sourceLines: inout [String]) {
        appendLines(Self.entryLines(entry), to: &sourceLines)
    }

    private static func entryLines(_ entry: OverrideEntry) -> [String] {
        let keyLine = entry.inlineValue.trimmedNonEmpty == nil
            ? "\(entry.key):"
            : "\(entry.key):\(entry.inlineValue)"
        return [keyLine] + entry.blockLines
    }

    private static func appendLines(_ lines: [String], to sourceLines: inout [String]) {
        if let last = sourceLines.last, !last.trimmed.isEmpty {
            sourceLines.append("")
        }
        sourceLines.append(contentsOf: lines)
    }

    // MARK: - Line helpers

    private static func topLevelKeyLineIndex(of key: String, in lines: [String]) -> Int? {
        lines.firstIndex { isTopLevelKeyLine($0, key: key) }
    }

    private static func isTopLevelKeyLine(_ line: String, key: String) -> Bool {
        guard Self.leadingWhitespaceCount(of: line) == 0 else { return false }
        let content = line.trimmed
        guard !content.isEmpty, !content.hasPrefix("#") else { return false }
        return content == "\(key):" || content.hasPrefix("\(key): ")
    }

    private static func valueText(afterKey key: String, inLine line: String) -> String {
        let content = line.trimmed
        let prefix = "\(key):"
        guard content.hasPrefix(prefix) else { return "" }
        return String(content.dropFirst(prefix.count))
    }

    private static func listIndent(in lines: [String], after keyIndex: Int) -> Int {
        var index = keyIndex + 1
        while index < lines.count {
            let line = lines[index]
            let indent = Self.leadingWhitespaceCount(of: line)
            let content = String(line.dropFirst(indent)).trimmed
            if content.isEmpty {
                index += 1
                continue
            }
            if content.hasPrefix("#") {
                index += 1
                continue
            }
            return indent > 0 ? indent : 2
        }
        return 2
    }

    private static func shifted(_ lines: [String], toIndent targetIndent: Int) -> [String] {
        guard let sourceIndent = Self.firstContentIndent(in: lines) else { return [] }
        let delta = targetIndent - sourceIndent
        guard delta != 0 else { return lines }

        return lines.map { line in
            guard line.trimmedNonEmpty != nil else { return "" }
            if delta > 0 {
                return String(repeating: " ", count: delta) + line
            }
            let removal = -delta
            let leadingSpaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(removal, leadingSpaces)))
        }
    }

    private static func normalizedLines(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while lines.last?.trimmed.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func leadingWhitespaceCount(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }
}
