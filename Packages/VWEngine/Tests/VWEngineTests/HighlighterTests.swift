import Testing
import VWStyle

@Suite struct HighlighterTests {
    /// The invariant that makes async application safe: token runs concatenate
    /// back to the exact input, for every language.
    @Test func losslessAcrossLanguages() {
        let samples: [(String, String)] = [
            ("swift", "func greet(_ name: String) -> String {\n  // says hi\n  return \"hi \\(name)\" + String(42)\n}"),
            ("python", "def f(x):\n    # comment\n    return f\"{x}\" * 0x1F  # trailing"),
            ("javascript", "const x = `tpl ${y}`; /* block */ let n = 1.5e-3;"),
            ("json", "{\"key\": [1, 2.5, true, null], \"s\": \"v\"}"),
            ("bash", "if [ -f \"$FILE\" ]; then\n  echo 'ok' # done\nfi"),
            ("rust", "fn main() { let x: i32 = 0b1010; println!(\"{}\", x); }"),
            ("go", "func main() {\n\ts := `raw`\n\t_ = s // ok\n}"),
            ("sql", "SELECT count(*) FROM users WHERE name = 'bob' -- all"),
            ("c", "#include <stdio.h>\nint main(void) { return 0; /* done */ }"),
        ]
        for (language, code) in samples {
            let runs = highlightCode(code, language: language)
            #expect(runs != nil, "\(language) not recognized")
            let rejoined = runs?.map(\.text).joined()
            #expect(rejoined == code, "\(language) lost bytes")
        }
    }

    @Test func classifiesSwiftTokens() {
        let runs = highlightCode(
            "func add() { // sum\n  let x = \"str\" + 42\n}", language: "swift"
        )!
        func colors(of text: String) -> ColorToken? {
            runs.first { $0.text == text }?.color
        }
        #expect(colors(of: "func") == .codeKeyword)
        #expect(colors(of: "let") == .codeKeyword)
        // Adjacent plain tokens merge into one run.
        #expect(runs.first { $0.text.contains("add") }?.color == .codeText)
        #expect(colors(of: "\"str\"") == .codeString)
        #expect(colors(of: "42") == .codeNumber)
        #expect(runs.first { $0.text.contains("// sum") }?.color == .codeComment)
        // Everything stays mono — highlighting must never change metrics.
        #expect(runs.allSatisfy { $0.traits == .mono })
    }

    @Test func stringsSwallowEscapesAndComments() {
        let runs = highlightCode(#"let s = "not // a comment \" still""#, language: "swift")!
        let string = runs.first { $0.color == .codeString }
        #expect(string?.text == #""not // a comment \" still""#)
        #expect(!runs.contains { $0.color == .codeComment })
    }

    @Test func tripleQuotedStrings() {
        let code = "x = \"\"\"multi\nline // not comment\n\"\"\"\ny = 1"
        let runs = highlightCode(code, language: "python")!
        let string = runs.first { $0.color == .codeString }
        #expect(string?.text.contains("multi\nline") == true)
        #expect(runs.first { $0.text == "1" }?.color == .codeNumber)
    }

    @Test func sqlKeywordsAreCaseInsensitive() {
        let runs = highlightCode("select id from t", language: "sql")!
        #expect(runs.first { $0.text == "select" }?.color == .codeKeyword)
        #expect(runs.first { $0.text == "from" }?.color == .codeKeyword)
        #expect(runs.first { $0.text.contains("id") }?.color == .codeText)
    }

    @Test func languageAliasesResolve() {
        #expect(highlightCode("x = 1", language: "py") != nil)
        #expect(highlightCode("x = 1", language: "TS") != nil)
        #expect(highlightCode("x = 1", language: "sh") != nil)
    }

    @Test func unknownLanguageReturnsNil() {
        #expect(highlightCode("whatever", language: "brainfuck") == nil)
        #expect(highlightCode("whatever", language: "") == nil)
    }
}
