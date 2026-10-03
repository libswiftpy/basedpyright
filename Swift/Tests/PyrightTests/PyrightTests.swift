//
//  PyrightTests.swift
//  basedpyright
//

import Foundation
import Testing
@testable import Pyright

@MainActor
@Suite(.serialized)
struct PyrightTests {
    static let pyright = Pyright(
        configuration: ["typeCheckingMode": "standard"],
        files: { ["typings/greeting.pyi": "def hello(name: str) -> str: ..."] }
    )

    @Test(arguments: [
        ("greet(|)", "name: str"),
        ("greet('Ada', |)", "count: int"),
        ("greet(count=|)", "count: int"),
        ("greet(\n    'Ada',\n    |\n)", "count: int"),
        ("greet(greet(|), 2)", "name: str"),
        ("greet(greet('Ada'), |)", "count: int"),
        ("greet('👍', |)", "count: int"),
        ("Greeter(|)", "name: str"),
    ])
    func signatureTracksTheArgument(marked: String, expected: String) async throws {
        let prelude = """
        def greet(name: str, count: int = 1) -> str:
            return name
        class Greeter:
            def __init__(self, name: str): pass

        """
        let source = prelude + marked.replacingOccurrences(of: "|", with: "")
        let before = prelude + marked.prefix(while: { $0 != "|" })
        let line = before.count(where: { $0 == "\n" }) + 1
        let character = before.split(separator: "\n", omittingEmptySubsequences: false).last?.utf16.count ?? 0
        let result = try #require(await Self.pyright.signatureHelp(in: source, line: line, character: character))
        let range = try #require(result.activeParameter)
        #expect((result.label as NSString).substring(with: range).hasPrefix(expected))
    }

    @Test func decodesOnlyTheActiveParametersDocumentation() throws {
        for documentation: Any in ["  Description  ", ["kind": "plaintext", "value": "Description"]] {
            let result = try #require(Pyright.SignatureHelp([
                "signatures": [[
                    "label": "(a: int, b: int)", "documentation": "Function documentation",
                    "parameters": [
                        ["label": [1, 7], "documentation": "Wrong parameter"],
                        ["label": [9, 15], "documentation": documentation],
                    ],
                    "activeParameter": 1,
                ]],
                "activeParameter": 0,
            ]))
            #expect(result.parameterDocumentation == "Description")
        }
        let empty = try #require(Pyright.SignatureHelp([
            "signatures": [["label": "(a: int)", "parameters": [
                ["label": [1, 7], "documentation": ["kind": "plaintext", "value": "  "]]
            ]]], "activeParameter": 0,
        ]))
        #expect(empty.parameterDocumentation == nil)
    }

    @Test func parameterDescriptionFromSimpleDocstring() async throws {
        let source = """
        def print_something(something: str, param: int | None = None) -> None:
            \"\"\"prints something

            something: something to print
            \"\"\"
            pass
        print_something()
        """
        let result = try #require(await Self.pyright.signatureHelp(in: source, line: 7, character: 16))
        #expect(result.parameterDocumentation?.contains("something to print") == true, "\(String(describing: result.parameterDocumentation))")
        let undocumented = try #require(await Self.pyright.signatureHelp(
            in: source.replacingOccurrences(of: "print_something()", with: "print_something('hi', )"),
            line: 7, character: 21
        ))
        #expect(undocumented.parameterDocumentation == nil)
    }

    @Test func noSignatureOutsideACall() async {
        let result = await Self.pyright.signatureHelp(in: "print()\nx = 1", line: 2, character: 5)
        #expect(result == nil)
    }

    @Test func tellsWhetherACallTakesArguments() async throws {
        let source = "class C:\n    def ping(self) -> None: ...\nC().ping()\nprint()"
        let ping = try #require(await Self.pyright.signatureHelp(in: source, line: 3, character: 9))
        #expect(!ping.takesArguments, "\(ping.label)")
        let print = try #require(await Self.pyright.signatureHelp(in: source, line: 4, character: 6))
        #expect(print.takesArguments)
    }

    @Test func keepsEveryOverloadWithTheMatchedOneSelected() async throws {
        let source = """
        from typing import overload
        @overload
        def f(a: int) -> int: ...
        @overload
        def f(a: str, b: str) -> str: ...
        def f(a, b=None): return a
        f('x', )
        """
        let result = try #require(await Self.pyright.signatureHelp(in: source, line: 7, character: 7))
        #expect(result.signatures.count == 2)
        #expect(result.label.contains("b: str"), "\(result.signatures.map(\.label))")
        #expect(result.signatures[result.selected] == result.signatures.first { $0.label.contains("b: str") })
    }

    @Test func decodesSelectedSignatureAndParameterOverride() throws {
        let result = try #require(Pyright.SignatureHelp([
            "signatures": [
                ["label": "(wrong: int)", "parameters": [["label": [1, 11]]]],
                ["label": "(a: str = '👍', b: int)", "parameters": [["label": [1, 14]], ["label": [16, 22]]],
                 "activeParameter": 1],
            ],
            "activeSignature": 1, "activeParameter": 0,
        ]))
        #expect(result.label == "(a: str = '👍', b: int)")
        #expect(result.activeParameter == NSRange(location: 16, length: 6))
    }

    @Test func separatesTheReturnTypeFromTheParameters() async throws {
        let decoded = try #require(Pyright.SignatureHelp([
            "signatures": [
                ["label": "(end: str = ') -> x') -> list[int]", "parameters": [["label": [1, 20]]]],
                ["label": "() -> None", "parameters": []],
                ["label": "(a)", "parameters": [["label": [1, 2]]]],
            ],
        ]))
        #expect(decoded.signatures.map(\.returnType) == ["list[int]", "None", nil])

        let source = "def greet(sep: str = ')') -> dict[str, int]: ...\ngreet()"
        let live = try #require(await Self.pyright.signatureHelp(in: source, line: 2, character: 6))
        #expect(live.signatures.first?.returnType == "dict[str, int]", "\(live.label)")
    }

    @Test(arguments: [-1, 2, 99])
    func invalidActiveParameterIsNotHighlighted(active: Int) throws {
        let result = try #require(Pyright.SignatureHelp([
            "signatures": [["label": "(a: int)", "parameters": [["label": [1, 7]]]]],
            "activeParameter": active,
        ]))
        #expect(result.activeParameter == nil)
    }

    @Test func missingParameterAndInvalidRangesAreNotHighlighted() throws {
        for parameter in [[:], ["label": [-1, 7]], ["label": [1, 100]], ["label": [7, 1]]] as [[String: Any]] {
            let result = try #require(Pyright.SignatureHelp([
                "signatures": [["label": "(a: int)", "parameters": [parameter]]],
                "activeParameter": 0,
            ]))
            #expect(result.activeParameter == nil)
        }
        #expect(Pyright.SignatureHelp(["signatures": []]) == nil)
    }

    @Test func fallsBackToFirstSignatureWithoutInventingAnActiveParameter() throws {
        let result = try #require(Pyright.SignatureHelp([
            "signatures": [["label": "(a: int)", "parameters": [["label": [1, 7]]]]],
            "activeSignature": 20,
        ]))
        #expect(result.label == "(a: int)")
        #expect(result.activeParameter == nil)
    }

    @Test func reportsATypeErrorWithItsRule() async {
        let items = await Self.pyright.diagnostics(for: "x = 1\nname: str = 42")
        #expect(items.map(\.line) == [2])
        #expect(items.first?.severity == .error)
        #expect(items.first?.rule != nil)
    }

    @Test func marksAnUnusedImportUnnecessary() async {
        let items = await Self.pyright.diagnostics(for: "import json\nx = 1")
        #expect(items.contains { $0.line == 1 && $0.isUnnecessary && $0.severity == .hint }, "\(items)")
        let used = await Self.pyright.diagnostics(for: "import json\nx = json.dumps(1)")
        #expect(!used.contains { $0.isUnnecessary })
    }

    @Test func reportsWhatDoesntParseWithoutARule() async {
        let items = await Self.pyright.diagnostics(for: "def f(:\n    pass")
        #expect(items.contains { $0.severity == .error && $0.rule == nil })
    }

    @Test func completesFromTheStandardLibrary() async {
        let items = await Self.pyright.completions(in: "import json\njson.lo", line: 2, character: 7)
        #expect(items.contains { $0.label == "loads" && $0.kind == .function })
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

    @Test func completesModulesAndKeywordsWithTheirKinds() async {
        let modules = await Self.pyright.completions(in: "import js", line: 1, character: 9)
        #expect(modules.contains { $0.label == "json" && $0.kind == .module })
        let keywords = await Self.pyright.completions(in: "impo", line: 1, character: 4)
        #expect(keywords.contains { $0.label == "import" && $0.kind == .keyword })
    }

    @Test func completesOnlyWhatsInScope() async {
        let unimported = await Self.pyright.completions(in: "OrderedDi", line: 1, character: 9)
        #expect(!unimported.contains { $0.label == "OrderedDict" }, "\(unimported.map(\.label))")
        let imported = await Self.pyright.completions(in: "from collections import OrderedDict\nOrderedDi", line: 2, character: 9)
        #expect(imported.contains { $0.label == "OrderedDict" })
    }

    @Test(arguments: [
        ("import agents\nagents.Agent.respond", "agents.Agent.respond"),
        ("import agents\na = agents.Agent()\na.respond", "agents.Agent.respond"),
        ("from agents import Agent\nAgent", "agents.Agent"),
        ("import json\njson.loads", "json.loads"),
        ("import mine\nmine.greet", "mine.greet"),
        ("'s'.join", "builtins.str.join"),
    ])
    func referencesWhatANameIsDeclaredAs(source: String, path: String) async {
        let pyright = Pyright(files: { [
            "typings/agents.pyi": "class Agent:\n    def __init__(self) -> None: ...\n    async def respond(self, prompt: str) -> str: ...\n",
            "mine.py": "def greet(name: str) -> str:\n    return name\n",
        ] })
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let found = await pyright.reference(in: source, line: lines.count, character: lines.last!.utf16.count)
        #expect(found == path)
    }

    @Test func referencesNothingForANameTheDocumentDeclares() async {
        let found = await Self.pyright.reference(in: "def mine(): ...\nmine", line: 2, character: 4)
        #expect(found == nil)
    }

    @Test func readsTheFilesItIsGiven() async {
        let items = await Self.pyright.completions(in: "import greeting\ngreeting.he", line: 2, character: 11)
        #expect(items.contains { $0.label == "hello" })
    }
}

