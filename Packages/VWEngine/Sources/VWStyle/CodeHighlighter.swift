import Foundation
import VWCore

// Table-driven syntax highlighter: strings, comments, numbers, keywords.
// Deliberately not a parser — it's a colorist for fenced code in a markdown
// reader, tuned for the languages LLMs actually emit. Pure function, safe to
// run off the main actor; output is COLOR-ONLY (same text, same .mono trait,
// same advances), so applying it never changes layout — that's what makes
// async application safe.

/// nil when the language isn't recognized (block stays plain).
/// Invariant: the concatenated run texts equal `code` exactly.
///
/// When `contentSpan` (the code's byte-verified source range) is provided,
/// each token gets an exact SourceSpan by UTF-8 accumulation — partial
/// selections in highlighted code stay byte-exact for source copy.
public func highlightCode(
    _ code: String, language: String, contentSpan: SourceSpan? = nil
) -> [StyledRun]? {
    guard let spec = LanguageSpec.spec(for: language) else { return nil }

    let scalars = Array(code.unicodeScalars)
    var tokens: [(kind: ColorToken, start: Int, end: Int)] = []
    var i = 0

    func matches(_ needle: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + needle.count <= scalars.count else { return false }
        for (offset, scalar) in needle.enumerated() where scalars[index + offset] != scalar {
            return false
        }
        return true
    }

    func append(_ kind: ColorToken, _ start: Int, _ end: Int) {
        if let last = tokens.last, last.kind == kind, last.end == start {
            tokens[tokens.count - 1].end = end
        } else {
            tokens.append((kind, start, end))
        }
    }

    while i < scalars.count {
        let c = scalars[i]

        // Line comments.
        if let comment = spec.lineComments.first(where: { matches($0, at: i) }) {
            let start = i
            i += comment.count
            while i < scalars.count, scalars[i] != "\n" { i += 1 }
            append(.codeComment, start, i)
            continue
        }

        // Block comments.
        if let (open, close) = spec.blockComments.first(where: { matches($0.0, at: i) }) {
            let start = i
            i += open.count
            while i < scalars.count, !matches(close, at: i) { i += 1 }
            i = min(i + close.count, scalars.count)
            append(.codeComment, start, i)
            continue
        }

        // Strings (triple-quoted first where the language has them).
        if spec.stringDelimiters.contains(c) {
            let start = i
            let quote = c
            let triple: [Unicode.Scalar] = [quote, quote, quote]
            if spec.tripleQuotes, matches(triple, at: i) {
                i += 3
                while i < scalars.count, !matches(triple, at: i) { i += 1 }
                i = min(i + 3, scalars.count)
            } else {
                i += 1
                while i < scalars.count {
                    if scalars[i] == "\\" { i = min(i + 2, scalars.count); continue }
                    if scalars[i] == quote { i += 1; break }
                    i += 1
                }
            }
            append(.codeString, start, i)
            continue
        }

        // Numbers.
        if c.properties.numericType != nil || (c == "." && i + 1 < scalars.count && scalars[i + 1].properties.numericType != nil) {
            let start = i
            i += 1
            while i < scalars.count {
                let s = scalars[i]
                if s.properties.numericType != nil || s == "." || s == "_"
                    || s == "x" || s == "X" || s == "o" || s == "O" || s == "b" || s == "B"
                    || ("a"..."f").contains(s) || ("A"..."F").contains(s) {
                    i += 1
                } else if s == "e" || s == "E", i + 1 < scalars.count,
                          scalars[i + 1].properties.numericType != nil || scalars[i + 1] == "-" || scalars[i + 1] == "+" {
                    i += 2
                } else {
                    break
                }
            }
            append(.codeNumber, start, i)
            continue
        }

        // Identifiers / keywords.
        if c.properties.isAlphabetic || c == "_" || (spec.atKeywords && c == "@") {
            let start = i
            i += 1
            while i < scalars.count {
                let s = scalars[i]
                if s.properties.isAlphabetic || s.properties.numericType != nil || s == "_" {
                    i += 1
                } else {
                    break
                }
            }
            var word = String(String.UnicodeScalarView(scalars[start..<i]))
            if spec.caseInsensitiveKeywords { word = word.uppercased() }
            append(spec.keywords.contains(word) ? .codeKeyword : .codeText, start, i)
            continue
        }

        append(.codeText, i, i + 1)
        i += 1
    }

    var byteOffset = contentSpan?.startUTF8
    return tokens.map { token in
        let text = String(String.UnicodeScalarView(scalars[token.start..<token.end]))
        var span: SourceSpan?
        if let start = byteOffset {
            let end = start + text.utf8.count
            span = SourceSpan(startUTF8: start, endUTF8: end)
            byteOffset = end
        }
        return StyledRun(text: text, traits: .mono, color: token.kind, span: span)
    }
}

// MARK: - Language table

struct LanguageSpec {
    let keywords: Set<String>
    let lineComments: [[Unicode.Scalar]]
    let blockComments: [(open: [Unicode.Scalar], close: [Unicode.Scalar])]
    let stringDelimiters: Set<Unicode.Scalar>
    let tripleQuotes: Bool
    let caseInsensitiveKeywords: Bool
    let atKeywords: Bool

    init(
        keywords: [String], lineComments: [String] = [], blockComments: [(String, String)] = [],
        strings: [Unicode.Scalar] = ["\"", "'"], tripleQuotes: Bool = false,
        caseInsensitive: Bool = false, atKeywords: Bool = false
    ) {
        self.keywords = Set(caseInsensitive ? keywords.map { $0.uppercased() } : keywords)
        self.lineComments = lineComments.map { Array($0.unicodeScalars) }
        self.blockComments = blockComments.map { (Array($0.0.unicodeScalars), Array($0.1.unicodeScalars)) }
        self.stringDelimiters = Set(strings)
        self.tripleQuotes = tripleQuotes
        self.caseInsensitiveKeywords = caseInsensitive
        self.atKeywords = atKeywords
    }

    static func spec(for language: String) -> LanguageSpec? {
        let normalized = language.lowercased().trimmingCharacters(in: .whitespaces)
        return specs[aliases[normalized] ?? normalized]
    }

    private static let aliases: [String: String] = [
        "py": "python", "python3": "python",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "shell-session": "bash",
        "rs": "rust",
        "golang": "go",
        "c++": "cpp", "cc": "cpp", "cxx": "cpp", "h": "c", "hpp": "cpp",
        "objective-c": "c", "objectivec": "c", "objc": "c", "m": "c",
        "kt": "kotlin", "kts": "kotlin",
        "rb": "ruby",
        "yml": "yaml",
    ]

    private static let cKeywords = [
        "int", "char", "long", "short", "unsigned", "signed", "float", "double", "void",
        "if", "else", "for", "while", "do", "switch", "case", "default", "return", "break",
        "continue", "struct", "union", "enum", "typedef", "static", "extern", "const",
        "volatile", "sizeof", "goto", "inline", "auto", "bool", "true", "false", "NULL",
    ]

    private static let specs: [String: LanguageSpec] = [
        "swift": LanguageSpec(
            keywords: [
                "func", "let", "var", "if", "else", "guard", "return", "switch", "case",
                "default", "for", "while", "repeat", "in", "class", "struct", "enum",
                "protocol", "extension", "import", "init", "deinit", "throws", "throw",
                "try", "catch", "do", "as", "is", "nil", "true", "false", "self", "super",
                "public", "private", "internal", "fileprivate", "open", "static", "final",
                "lazy", "weak", "unowned", "mutating", "override", "required", "convenience",
                "associatedtype", "typealias", "where", "defer", "break", "continue",
                "fallthrough", "operator", "subscript", "actor", "await", "async", "some",
                "any", "inout", "indirect", "package", "borrowing", "consuming",
            ],
            lineComments: ["//"], blockComments: [("/*", "*/")],
            strings: ["\""], tripleQuotes: true
        ),
        "python": LanguageSpec(
            keywords: [
                "def", "return", "if", "elif", "else", "for", "while", "in", "not", "and",
                "or", "is", "None", "True", "False", "class", "import", "from", "as",
                "with", "try", "except", "finally", "raise", "pass", "break", "continue",
                "lambda", "global", "nonlocal", "yield", "assert", "del", "async", "await",
                "match", "case", "print", "self",
            ],
            lineComments: ["#"], strings: ["\"", "'"], tripleQuotes: true
        ),
        "javascript": LanguageSpec(
            keywords: [
                "function", "return", "if", "else", "for", "while", "do", "switch", "case",
                "default", "break", "continue", "new", "delete", "typeof", "instanceof",
                "in", "of", "var", "let", "const", "class", "extends", "super", "this",
                "null", "undefined", "true", "false", "import", "export", "from", "as",
                "async", "await", "yield", "try", "catch", "finally", "throw", "void",
                "static", "get", "set",
            ],
            lineComments: ["//"], blockComments: [("/*", "*/")],
            strings: ["\"", "'", "`"]
        ),
        "typescript": LanguageSpec(
            keywords: [
                "function", "return", "if", "else", "for", "while", "do", "switch", "case",
                "default", "break", "continue", "new", "delete", "typeof", "instanceof",
                "in", "of", "var", "let", "const", "class", "extends", "super", "this",
                "null", "undefined", "true", "false", "import", "export", "from", "as",
                "async", "await", "yield", "try", "catch", "finally", "throw", "void",
                "static", "get", "set", "interface", "type", "implements", "enum",
                "public", "private", "protected", "readonly", "namespace", "declare",
                "abstract", "satisfies", "keyof", "infer", "never", "unknown", "any",
                "string", "number", "boolean", "object", "symbol",
            ],
            lineComments: ["//"], blockComments: [("/*", "*/")],
            strings: ["\"", "'", "`"]
        ),
        "json": LanguageSpec(keywords: ["true", "false", "null"], strings: ["\""]),
        "bash": LanguageSpec(
            keywords: [
                "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                "esac", "function", "in", "echo", "exit", "return", "local", "export",
                "readonly", "source", "set", "unset", "shift", "break", "continue",
                "until", "select", "declare", "eval", "cd", "sudo",
            ],
            lineComments: ["#"], strings: ["\"", "'"]
        ),
        "rust": LanguageSpec(
            keywords: [
                "fn", "let", "mut", "if", "else", "match", "loop", "while", "for", "in",
                "return", "impl", "trait", "struct", "enum", "mod", "pub", "use", "crate",
                "super", "self", "Self", "static", "const", "unsafe", "async", "await",
                "move", "ref", "where", "as", "dyn", "true", "false", "type", "continue",
                "break", "extern", "macro_rules",
            ],
            lineComments: ["//"], blockComments: [("/*", "*/")], strings: ["\""]
        ),
        "go": LanguageSpec(
            keywords: [
                "func", "var", "const", "if", "else", "for", "range", "switch", "case",
                "default", "return", "break", "continue", "package", "import", "type",
                "struct", "interface", "map", "chan", "go", "defer", "select",
                "fallthrough", "goto", "nil", "true", "false", "iota", "make", "new",
                "len", "cap", "append", "error", "string", "int", "bool",
            ],
            lineComments: ["//"], blockComments: [("/*", "*/")], strings: ["\"", "`"]
        ),
        "c": LanguageSpec(
            keywords: cKeywords,
            lineComments: ["//"], blockComments: [("/*", "*/")], atKeywords: true
        ),
        "cpp": LanguageSpec(
            keywords: cKeywords + [
                "class", "namespace", "template", "typename", "public", "private",
                "protected", "virtual", "override", "new", "delete", "this", "nullptr",
                "using", "try", "catch", "throw", "constexpr", "noexcept", "friend",
                "operator", "explicit", "mutable",
            ],
            lineComments: ["//"], blockComments: [("/*", "*/")]
        ),
        "java": LanguageSpec(
            keywords: [
                "class", "interface", "extends", "implements", "public", "private",
                "protected", "static", "final", "abstract", "synchronized", "instanceof",
                "null", "true", "false", "new", "this", "super", "void", "int", "long",
                "short", "byte", "char", "float", "double", "boolean", "if", "else",
                "for", "while", "do", "switch", "case", "default", "return", "break",
                "continue", "try", "catch", "finally", "throw", "throws", "import",
                "package", "enum", "record", "var",
            ],
            lineComments: ["//"], blockComments: [("/*", "*/")]
        ),
        "kotlin": LanguageSpec(
            keywords: [
                "fun", "val", "var", "if", "else", "when", "for", "while", "return",
                "class", "object", "interface", "data", "sealed", "enum", "import",
                "package", "null", "true", "false", "is", "in", "as", "this", "super",
                "override", "open", "abstract", "final", "lateinit", "by", "companion",
                "init", "constructor", "suspend", "try", "catch", "finally", "throw",
            ],
            lineComments: ["//"], blockComments: [("/*", "*/")],
            strings: ["\""], tripleQuotes: true
        ),
        "ruby": LanguageSpec(
            keywords: [
                "def", "end", "if", "elsif", "else", "unless", "while", "until", "for",
                "in", "do", "return", "class", "module", "require", "begin", "rescue",
                "ensure", "raise", "yield", "self", "nil", "true", "false", "and", "or",
                "not", "then", "case", "when", "break", "next", "lambda", "proc", "puts",
                "attr_accessor", "attr_reader", "new",
            ],
            lineComments: ["#"], strings: ["\"", "'"]
        ),
        "css": LanguageSpec(
            keywords: ["important", "inherit", "initial", "unset", "auto", "none"],
            blockComments: [("/*", "*/")], strings: ["\"", "'"]
        ),
        "yaml": LanguageSpec(
            keywords: ["true", "false", "null", "yes", "no"],
            lineComments: ["#"], strings: ["\"", "'"]
        ),
        "sql": LanguageSpec(
            keywords: [
                "select", "from", "where", "insert", "into", "values", "update", "set",
                "delete", "join", "left", "right", "inner", "outer", "on", "group", "by",
                "order", "limit", "offset", "create", "table", "index", "drop", "alter",
                "and", "or", "not", "null", "in", "as", "distinct", "having", "union",
                "primary", "key", "foreign", "references", "unique", "default", "exists",
                "between", "like", "asc", "desc", "count", "sum", "avg", "min", "max",
            ],
            lineComments: ["--"], blockComments: [("/*", "*/")],
            strings: ["'"], caseInsensitive: true
        ),
        "markdown": LanguageSpec(keywords: [], lineComments: []),
    ]
}
