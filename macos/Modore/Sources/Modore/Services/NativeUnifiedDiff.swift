import Foundation

/// Standard unified hunks with three context lines. Work is bounded after
/// trimming common edges, so a large unchanged skill stays cheap to compare.
enum NativeUnifiedDiff {
    private struct Row {
        let prefix: String
        let text: String
        let old: Int
        let new: Int
    }
    static func render(_ before: String, _ after: String, from: String, to: String) -> String {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var result = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let terminated = text.hasSuffix("\n")
            if terminated { result.removeLast() }
            return result.enumerated().map { index, line in line + (index < result.count - 1 || terminated ? "\n" : "") }
        }
        let a = lines(before), b = lines(after)
        func equal(_ x: String, _ y: String) -> Bool { x.utf8.elementsEqual(y.utf8) }
        var leading = 0, trailing = 0
        while leading < min(a.count, b.count), equal(a[leading], b[leading]) { leading += 1 }
        while trailing < min(a.count, b.count) - leading, equal(a[a.count - trailing - 1], b[b.count - trailing - 1]) { trailing += 1 }
        guard leading != a.count || leading != b.count else { return "" }
        let oldMiddle = Array(a[leading..<a.count - trailing]), newMiddle = Array(b[leading..<b.count - trailing])
        let removed: Set<Int>, inserted: Set<Int>
        if oldMiddle.count + newMiddle.count <= 40_000 && oldMiddle.count <= 4_000_000 / max(1, newMiddle.count) {
            let difference = newMiddle.difference(from: oldMiddle, by: equal)
            removed = Set(difference.removals.map { change in if case .remove(let offset, _, _) = change { return offset }; return -1 })
            inserted = Set(difference.insertions.map { change in if case .insert(let offset, _, _) = change { return offset }; return -1 })
        } else {
            removed = Set(oldMiddle.indices); inserted = Set(newMiddle.indices)
        }
        var rows: [Row] = [], i = 0, j = 0
        func append(_ prefix: String, _ text: String) { rows.append(Row(prefix: prefix, text: text, old: i, new: j)) }
        while i < a.count || j < b.count {
            if i >= leading && i < a.count - trailing && removed.contains(i - leading) { append("-", a[i]); i += 1 }
            else if j >= leading && j < b.count - trailing && inserted.contains(j - leading) { append("+", b[j]); j += 1 }
            else if i < a.count && j < b.count { append(" ", a[i]); i += 1; j += 1 }
            else if i < a.count { append("-", a[i]); i += 1 }
            else { append("+", b[j]); j += 1 }
        }
        var ranges: [Range<Int>] = []
        for index in rows.indices where rows[index].prefix != " " {
            let range = max(0, index - 3)..<min(rows.count, index + 4)
            if let previous = ranges.last, range.lowerBound <= previous.upperBound {
                ranges[ranges.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else { ranges.append(range) }
        }
        var output = ["--- " + from, "+++ " + to]
        func location(_ start: Int, _ count: Int) -> String { count == 1 ? String(start + 1) : "\(count == 0 ? start : start + 1),\(count)" }
        for range in ranges {
            let hunk = rows[range], first = rows[range.lowerBound]
            let oldCount = hunk.filter { $0.prefix != "+" }.count, newCount = hunk.filter { $0.prefix != "-" }.count
            output.append("@@ -\(location(first.old, oldCount)) +\(location(first.new, newCount)) @@")
            for row in hunk {
                output.append(row.prefix + (row.text.hasSuffix("\n") ? String(row.text.dropLast()) : row.text))
                if !row.text.hasSuffix("\n") { output.append("\\ No newline at end of file") }
            }
        }
        return output.joined(separator: "\n") + "\n"
    }
}
