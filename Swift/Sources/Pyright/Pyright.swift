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
        public let label: String
        /// A function, method or class: what's completed with a call.
        public let isCallable: Bool
    }

    public struct SignatureHelp: Sendable, Equatable {
        public let label: String
        public let activeParameter: NSRange?
        public let parameterDocumentation: String?

        init?(_ result: [String: Any]) {
            guard let signatures = result["signatures"] as? [[String: Any]],
                  !signatures.isEmpty else { return nil }
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
                // Method, function, constructor, class.
                let callable: Set<Int> = [2, 3, 4, 7]
                return Completion(label: label, isCallable: callable.contains(item["kind"] as? Int ?? 0))
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
