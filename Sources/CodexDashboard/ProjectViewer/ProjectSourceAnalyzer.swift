import Foundation

struct ProjectFunction: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let startLine: Int
    let endLine: Int
    var lineCount: Int { endLine - startLine + 1 }
}

/// A bounded lexical outline, not a compiler or a complexity score.
/// Masking literals/comments keeps their braces and fake declarations out of counts.
enum ProjectSourceAnalyzer {
    static let supportedExtensions: Set<String> = [
        "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "pyw",
        "rs", "go", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "cs"
    ]

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let bytes = text.utf8
        let count = bytes.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        return count + (bytes.last == 10 ? 0 : 1)
    }

    static func functions(in text: String, extension ext: String) -> [ProjectFunction] {
        guard supportedExtensions.contains(ext) else { return [] }
        let masked = mask(text, python: ["py", "pyw"].contains(ext), rust: ext == "rs")
        if ["py", "pyw"].contains(ext) { return pythonFunctions(masked.components(separatedBy: "\n")) }
        let source = masked as NSString
        // Regex matches and line offsets both use UTF-16.
        var lineStarts = [0]
        for (offset, codeUnit) in masked.utf16.enumerated() where codeUnit == 10 {
            lineStarts.append(offset + 1)
        }
        func lineNumber(at offset: Int) -> Int {
            var lower = 0
            var upper = lineStarts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if lineStarts[middle] <= offset { lower = middle + 1 }
                else { upper = middle }
            }
            return lower
        }
        // Supported declaration forms: named functions, arrow assignments, and methods.
        let patterns = [
            #"\b(?:func|function|fn|fun)\s+(?:\([^\n]*?\)\s*)?([A-Za-z_$][\w$]*)\s*(?:<[^\n{};]*>)?\s*\("#,
            #"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=\n]+)?=\s*(?:async\s+)?(?:\([^;{}]*?\)|[A-Za-z_$][\w$]*)\s*(?::[^=\n{]+)?=>"#,
            #"(?m)^\s*(?:(?:public|private|protected|internal|static|override|final|async|mutating|nonisolated|suspend|virtual|inline|export|default|abstract|open|readonly)\s+)*(?:[A-Za-z_$][\w$<>\[\]?.]*\s+)?([A-Za-z_$][\w$]*)\s*\([^;{}]*?\)\s*(?:async\s*)?(?:throws\s*)?(?::[^{};=]+)?\s*\{"#
        ]
        let excluded: Set<String> = ["if", "while", "for", "switch", "catch", "with", "when", "synchronized"]
        var declarations: [(name: String, start: Int, end: Int)] = []
        var usedBodies = Set<Int>()
        let full = NSRange(location: 0, length: source.length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: masked, range: full) {
                let name = source.substring(with: match.range(at: 1))
                guard !excluded.contains(name) else { continue }
                // Find the body without crossing a declaration terminator. Bound work
                // for incomplete source while Codex is in the middle of an edit.
                let searchEnd = min(source.length, NSMaxRange(match.range) + 2000)
                var body: Int?
                var cursor = match.range.location
                while cursor < searchEnd {
                    let c = source.character(at: cursor)
                    if c == 123 { body = cursor; break }
                    if c == 59 { break }
                    cursor += 1
                }
                guard let body, usedBodies.insert(body).inserted else { continue }
                var depth = 1
                cursor = body + 1
                while cursor < source.length && depth > 0 {
                    let c = source.character(at: cursor)
                    if c == 123 { depth += 1 }
                    if c == 125 { depth -= 1 }
                    cursor += 1
                }
                guard depth == 0 else { continue }
                let start = lineNumber(at: match.range(at: 1).location)
                let end = lineNumber(at: cursor)
                declarations.append((name, start, end))
            }
        }
        return identify(declarations.sorted { $0.start < $1.start })
    }

    private static func pythonFunctions(_ lines: [String]) -> [ProjectFunction] {
        let regex = try! NSRegularExpression(pattern: #"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\("#)
        var declarations: [(name: String, start: Int, end: Int)] = []
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let indent = indentation(line)
            var end = index
            var signatureComplete = line.contains(":")
            for next in (index + 1)..<lines.count {
                let candidate = lines[next]
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if !signatureComplete {
                    signatureComplete = candidate.contains(":")
                    end = next
                    continue
                }
                if indentation(candidate) <= indent { break }
                end = next
            }
            declarations.append((ns.substring(with: match.range(at: 1)), index + 1, end + 1))
        }
        return identify(declarations)
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 8 : 1) }
    }

    private static func identify(_ declarations: [(name: String, start: Int, end: Int)]) -> [ProjectFunction] {
        var occurrences: [String: Int] = [:]
        return declarations.map { declaration in
            let parents = declarations.filter { $0.start < declaration.start && $0.end >= declaration.end }
                .map(\.name)
            let key = (parents + [declaration.name]).joined(separator: ".")
            let ordinal = occurrences[key, default: 0]
            occurrences[key] = ordinal + 1
            return ProjectFunction(id: "\(key)#\(ordinal)", name: declaration.name,
                                   startLine: declaration.start, endLine: declaration.end)
        }
    }

    static func mask(_ text: String, python: Bool, rust: Bool = false) -> String {
        var chars = Array(text)
        var index = 0
        var quote: Character?
        var triple = false
        var blockDepth = 0
        while index < chars.count {
            let c = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if blockDepth > 0 {
                if c == "/", next == "*" { chars[index] = " "; chars[index + 1] = " "; blockDepth += 1; index += 2; continue }
                if c == "*", next == "/" { chars[index] = " "; chars[index + 1] = " "; blockDepth -= 1; index += 2; continue }
                if c != "\n" { chars[index] = " " }
            } else if let q = quote {
                if c == "\\", index + 1 < chars.count {
                    chars[index] = " "
                    if chars[index + 1] != "\n" { chars[index + 1] = " " }
                    index += 2; continue
                }
                if c == q {
                    if !triple { quote = nil }
                    else if index + 2 < chars.count, chars[index + 1] == q, chars[index + 2] == q {
                        chars[index + 1] = " "; chars[index + 2] = " "; quote = nil; index += 2
                    }
                }
                if c != "\n" { chars[index] = " " }
            } else if (python && c == "#") || (!python && c == "/" && next == "/") {
                while index < chars.count, chars[index] != "\n" { chars[index] = " "; index += 1 }
                continue
            } else if !python && c == "/" && next == "*" {
                chars[index] = " "; chars[index + 1] = " "; blockDepth = 1; index += 2; continue
            } else if c == "\"" || c == "'" || c == "`" {
                // Rust lifetimes and Swift argument labels are not string literals.
                if c == "'", rust, next?.isLetter == true,
                   (index + 2 >= chars.count || chars[index + 2] != "'") { index += 1; continue }
                quote = c
                triple = c != "`" && index + 2 < chars.count && chars[index + 1] == c && chars[index + 2] == c
                chars[index] = " "
                if triple { chars[index + 1] = " "; chars[index + 2] = " "; index += 2 }
            }
            index += 1
        }
        return String(chars)
    }
}
