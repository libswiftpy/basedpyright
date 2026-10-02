//
//  PyrightTests.swift
//  basedpyright
//

import Testing
@testable import Pyright

@MainActor
@Suite(.serialized)
struct PyrightTests {
    static let pyright = Pyright(
        configuration: ["typeCheckingMode": "standard"],
        files: { ["typings/greeting.pyi": "def hello(name: str) -> str: ..."] }
    )

    @Test func reportsATypeErrorWithItsRule() async {
        let items = await Self.pyright.diagnostics(for: "x = 1\nname: str = 42")
        #expect(items.map(\.line) == [2])
        #expect(items.first?.severity == .error)
        #expect(items.first?.rule != nil)
    }

    @Test func reportsWhatDoesntParseWithoutARule() async {
        let items = await Self.pyright.diagnostics(for: "def f(:\n    pass")
        #expect(items.contains { $0.severity == .error && $0.rule == nil })
    }

    @Test func completesFromTheStandardLibrary() async {
        let items = await Self.pyright.completions(in: "import json\njson.lo", line: 2, character: 7)
        #expect(items.contains { $0.label == "loads" && $0.isCallable })
    }

    @Test func readsChangedFilesAfterReload() async {
        var files = ["mine.py": "def first() -> None: ..."]
        let pyright = Pyright(files: { files })
        let source = "import mine\nmine."
        let before = await pyright.completions(in: source, line: 2, character: 5)
        #expect(before.map(\.label).contains("first"))

        files["mine.py"] = "def second() -> None: ..."
        pyright.reload()
        let after = await pyright.completions(in: source, line: 2, character: 5)
        #expect(after.map(\.label).contains("second"))
        #expect(!after.map(\.label).contains("first"))
    }

    @Test func readsTheFilesItIsGiven() async {
        let items = await Self.pyright.completions(in: "import greeting\ngreeting.he", line: 2, character: 11)
        #expect(items.contains { $0.label == "hello" })
    }
}

