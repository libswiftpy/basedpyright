//
//  Pyright.swift
//  basedpyright
//

import Foundation
import OSLog
import WebKit

/// basedpyright, run by WebKit in a web view that's never shown: WebKit's
/// process can compile JavaScript, an app's own can't. It starts on first use.
@MainActor
public final class Pyright {
    public struct Diagnostic: Sendable, Hashable {
        public enum Severity: Int, Sendable {
            case error = 1, warning, information, hint
        }

        /// 1-based, in the document's own lines and UTF-16 columns.
        public let line: Int
        public let column: Int
        public let endLine: Int
        public let endColumn: Int
        public let severity: Severity
        public let message: String
        /// The rule that reported it; none for what didn't parse.
        public let rule: String?
    }

    public struct Completion: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case function, method, constructor, `class`, module, variable, property, keyword, constant, other

            /// From the language server protocol's `CompletionItemKind`.
            init(_ number: Int) {
                self = switch number {
                case 2: .method
                case 3: .function
                case 4: .constructor
                case 7, 8, 13, 22: .class
                case 9: .module
                case 5, 10: .property
                case 6, 25: .variable
                case 14: .keyword
                case 12, 20, 21: .constant
                default: .other
                }
            }
        }

        public let label: String
        public let kind: Kind

        /// A function, method or class: what's completed with a call.
        public var isCallable: Bool {
            [.function, .method, .constructor, .class].contains(kind)
        }
    }

    public struct SignatureHelp: Sendable, Equatable {
        public let label: String
        public let activeParameter: NSRange?
        public let parameterDocumentation: String?
        /// Some signature, of all the overloads, has a parameter.
        public let takesArguments: Bool
        /// Some signature is one that's called without arguments: every
        /// parameter is optional, and it doesn't open with `*args` as `print` does.
        public let canOmitArguments: Bool

        init?(_ result: [String: Any]) {
            guard let signatures = result["signatures"] as? [[String: Any]],
                  !signatures.isEmpty else { return nil }
            // Pyright lists `/` and `*` as parameters too.
            let parameterLists = signatures.map { signature in
                Self.parameters(of: signature).filter { $0 != "/" && $0 != "*" }
            }
            takesArguments = parameterLists.contains { !$0.isEmpty }
            canOmitArguments = parameterLists.contains { parameters in
                let variadic = parameters.first.map { $0.hasPrefix("*") && !$0.hasPrefix("**") } ?? false
                return !variadic && parameters.allSatisfy { $0.contains("=") || $0.hasPrefix("*") }
            }
            let selected = result["activeSignature"] as? Int ?? 0
            let signature = signatures[signatures.indices.contains(selected) ? selected : 0]
            guard let label = signature["label"] as? String else { return nil }
            self.label = label
            let parameters = signature["parameters"] as? [[String: Any]] ?? []
            let active = signature["activeParameter"] as? Int ?? result["activeParameter"] as? Int
            if let active, parameters.indices.contains(active) {
                let documentation = parameters[active]["documentation"]
                let text = (documentation as? String
                    ?? (documentation as? [String: Any])?["value"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                parameterDocumentation = text.flatMap { $0.isEmpty ? nil : $0 }
            } else {
                parameterDocumentation = nil
            }
            if let active, parameters.indices.contains(active),
               let offsets = parameters[active]["label"] as? [Int],
               offsets.count == 2, offsets[0] >= 0, offsets[1] > offsets[0],
               offsets[1] <= label.utf16.count {
                let range = NSRange(location: offsets[0], length: offsets[1] - offsets[0])
                if let bounds = Range(range, in: label),
                   label.indices.contains(bounds.lowerBound),
                   bounds.upperBound == label.endIndex || label.indices.contains(bounds.upperBound) {
                    activeParameter = range
                } else {
                    activeParameter = nil
                }
            } else {
                activeParameter = nil
            }
        }

        /// The text of each parameter, from its label or its offsets in the signature's.
        private static func parameters(of signature: [String: Any]) -> [String] {
            let label = signature["label"] as? String ?? ""
            return (signature["parameters"] as? [[String: Any]] ?? []).compactMap { parameter in
                if let text = parameter["label"] as? String { return text }
                guard let offsets = parameter["label"] as? [Int], offsets.count == 2,
                      offsets[0] >= 0, offsets[1] >= offsets[0], offsets[1] <= label.utf16.count
                else { return nil }
                let utf16 = label.utf16
                return String(utf16[utf16.index(utf16.startIndex, offsetBy: offsets[0])..<utf16.index(utf16.startIndex, offsetBy: offsets[1])])
            }
        }
    }

    private let log = Logger(subsystem: "Pyright", category: "Pyright")
    private let configuration: String
    private let files: @MainActor () -> [String: String]
    private var webView: WKWebView?
    private var started: Task<Void, Error>?

    /// - Parameters:
    ///   - configuration: What a `pyrightconfig.json` holds.
    ///   - files: Files beside the documents, by path from the project root
    ///     (stubs under `typings/`); asked for when pyright starts, and again
    ///     after ``reload()``.
    public init(
        configuration: [String: any Sendable] = [:],
        files: @escaping @MainActor () -> [String: String] = { [:] }
    ) {
        // The bundled stubs: without them nothing, `str` included, is known.
        var configuration = configuration
        configuration["typeshedPath"] = configuration["typeshedPath"] ?? "/typeshed"
        let data = try? JSONSerialization.data(withJSONObject: configuration)
        self.configuration = data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        self.files = files
    }

    /// The diagnostics of `text`, or none when pyright can't start or a newer
    /// text replaced it first.
    public func diagnostics(for text: String, document: String = "main.py") async -> [Diagnostic] {
        let items = await call("return await check(uri, text)", [
            "uri": Self.uri(document), "text": text,
        ]) as? [[String: Any]] ?? []
        return items.compactMap(Diagnostic.init)
    }

    /// Completions at a 1-based `line` and a UTF-16 `character` offset in it.
    public func completions(
        in text: String, line: Int, character: Int, document: String = "main.py"
    ) async -> [Completion] {
        let items = await call("return await complete(uri, text, line, character)", [
            "uri": Self.uri(document), "text": text, "line": line - 1, "character": character,
        ]) as? [[String: Any]] ?? []
        return items
            .sorted { ($0["sortText"] as? String ?? "") < ($1["sortText"] as? String ?? "") }
            .compactMap { item in
                guard let label = item["label"] as? String else { return nil }
                return Completion(label: label, kind: Completion.Kind(item["kind"] as? Int ?? 0))
            }
    }

    /// Signature at a 1-based line and UTF-16 character offset.
    public func signatureHelp(
        in text: String, line: Int, character: Int, document: String = "main.py"
    ) async -> SignatureHelp? {
        guard let result = await call("return await signatureHelp(uri, text, line, character)", [
            "uri": Self.uri(document), "text": text, "line": line - 1, "character": character,
        ]) as? [String: Any] else { return nil }
        return SignatureHelp(result)
    }

    /// The dotted path of what the name at a 1-based line and UTF-16
    /// `character` is declared as, such as `agents.Agent.respond`; nil for a
    /// name the document declares itself, or none found.
    public func reference(in text: String, line: Int, character: Int, document: String = "main.py") async -> String? {
        guard let location = await call("return await definition(uri, text, line, character)", [
                  "uri": Self.uri(document), "text": text, "line": line - 1, "character": character,
              ]) as? [String: Any],
              let uri = location["uri"] as? String, uri != Self.uri(document),
              let start = (location["range"] as? [String: Any])?["start"] as? [String: Int],
              let module = Self.module(uri)
        else { return nil }

        let symbols = await call("return await symbols(uri)", ["uri": uri]) as? [[String: Any]] ?? []
        let declared = start["line"] ?? 0
        // An overload's position isn't listed: only one of them is a symbol.
        guard let names = Self.path(to: (declared, start["character"] ?? 0), in: symbols)
                ?? Self.name(at: character, of: text, line: line).map({ Self.classes(around: declared, in: symbols) + [$0] })
        else { return nil }
        return ([module] + names).joined(separator: ".")
    }

    /// The module a declaring file is, from its path among the files pyright reads.
    static func module(_ uri: String) -> String? {
        guard var path = URL(string: uri)?.path(percentEncoded: false) else { return nil }
        for root in ["/src/typings/", "/src/site-packages/", "/typeshed/stdlib/", "/src/"] where path.hasPrefix(root) {
            path.removeFirst(root.count)
            break
        }
        for suffix in [".pyi", ".py"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        if path.hasSuffix("/__init__") { path.removeLast("/__init__".count) }
        let module = path.replacingOccurrences(of: "/", with: ".")
        return module.isEmpty || module.hasPrefix(".") ? nil : module
    }

    /// The names down to the symbol whose name starts at `position`,
    /// outermost first, or nil where none does.
    static func path(to position: (line: Int, character: Int), in symbols: [[String: Any]]) -> [String]? {
        for symbol in symbols {
            guard let name = symbol["name"] as? String else { continue }
            let selection = (symbol["selectionRange"] as? [String: Any])?["start"] as? [String: Int]
            if selection?["line"] == position.line, selection?["character"] == position.character {
                return [name]
            }
            if let inner = path(to: position, in: symbol["children"] as? [[String: Any]] ?? []) {
                return [name] + inner
            }
        }
        return nil
    }

    /// The classes whose body holds `line`, outermost first.
    static func classes(around line: Int, in symbols: [[String: Any]]) -> [String] {
        for symbol in symbols where symbol["kind"] as? Int == 5 {
            guard let name = symbol["name"] as? String,
                  let range = symbol["range"] as? [String: Any],
                  let start = (range["start"] as? [String: Int])?["line"],
                  let end = (range["end"] as? [String: Int])?["line"],
                  (start...end).contains(line)
            else { continue }
            return [name] + classes(around: line, in: symbol["children"] as? [[String: Any]] ?? [])
        }
        return []
    }

    /// The identifier that ends at a UTF-16 `character` of a 1-based `line`.
    static func name(at character: Int, of text: String, line: Int) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.indices.contains(line - 1) else { return nil }
        let utf16 = Array(lines[line - 1].utf16.prefix(character))
        let before = String(decoding: utf16, as: UTF16.self)
        let name = before.reversed().prefix { $0 == "_" || $0.isLetter || $0.isNumber }
        return name.isEmpty ? nil : String(name.reversed())
    }

    /// Starts over on the next call, which asks for the files again.
    public func reload() {
        webView = nil
        started = nil
    }

    private static func uri(_ document: String) -> String {
        "file:///src/" + document
    }

    private func call(_ script: String, _ arguments: [String: Any]) async -> Any? {
        do {
            try await start().value
            return try await webView?.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
        } catch {
            log.error("\(error)")
            return nil
        }
    }

    private func start() -> Task<Void, Error> {
        if let started { return started }

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ResourceHandler(), forURLScheme: "pyright")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView
        webView.load(URLRequest(url: URL(string: "pyright://app/index.html")!))

        let task = Task {
            while try await webView.evaluateJavaScript("typeof start") as? String != "function" {
                try await Task.sleep(for: .milliseconds(20))
            }
            let files = Dictionary(uniqueKeysWithValues: self.files().map { ("/src/" + $0.key, $0.value) })
            _ = try await webView.callAsyncJavaScript(
                "await start(files, config)",
                arguments: ["files": files, "config": self.configuration],
                contentWorld: .page
            )
        }
        started = task
        return task
    }
}

extension Pyright.Diagnostic {
    init?(_ item: [String: Any]) {
        guard let range = item["range"] as? [String: Any],
              let start = range["start"] as? [String: Int],
              let end = range["end"] as? [String: Int],
              let line = start["line"],
              let message = item["message"] as? String
        else { return nil }
        self.init(
            line: line + 1,
            column: (start["character"] ?? 0) + 1,
            endLine: (end["line"] ?? line) + 1,
            endColumn: (end["character"] ?? 0) + 1,
            severity: Severity(rawValue: item["severity"] as? Int ?? 1) ?? .error,
            message: message,
            rule: item["code"] as? String
        )
    }
}

/// Serves the page and the worker from the bundle, so pyright starts offline.
private final class ResourceHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              let file = Bundle.module.url(forResource: url.lastPathComponent, withExtension: nil),
              let data = try? Data(contentsOf: file)
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = url.pathExtension == "html" ? "text/html" : "text/javascript"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
