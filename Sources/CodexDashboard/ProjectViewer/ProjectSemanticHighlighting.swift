import AppKit

struct ProjectSemanticToken: Decodable, Equatable, Sendable {
    let offset: Int
    let length: Int
    let type: String
}

enum ProjectSemanticHighlighting {
    static func tokens(text: String, path: String) async -> [ProjectSemanticToken] {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let fm = FileManager.default
        let engine: String
        var engineArguments: [String] = []
        if ext == "swift" {
            engine = "swift"
        } else if ["js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts"].contains(ext) {
            engine = "typescript"
            let libraries = [
                "/Applications/IntelliJ IDEA.app/Contents/plugins/javascript-impl/jsLanguageServicesImpl/external/tsserverlibrary.js",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/node_modules/typescript/lib/typescript.js",
                "/opt/homebrew/lib/node_modules/typescript/lib/typescript.js",
                "/usr/local/lib/node_modules/typescript/lib/typescript.js",
            ]
            guard let library = libraries.first(where: { fm.isReadableFile(atPath: $0) }) else { return [] }
            engineArguments = [library]
        } else {
            return []
        }

        let executables = ["/opt/homebrew/bin/node", "/opt/homebrew/opt/node@20/bin/node", "/usr/local/bin/node"]
        guard let node = executables.first(where: { fm.isExecutableFile(atPath: $0) }),
              let helper = InjectionBundle.defaultResourceBundle.url(
                forResource: "semantic-tokens", withExtension: "cjs", subdirectory: "Dashboard/ProjectViewer"
              ) else { return [] }

        // A temporary input file avoids blocking on a pipe with a large document.
        let input = fm.temporaryDirectory.appendingPathComponent("dashboard-source-\(UUID().uuidString)")
        guard fm.createFile(atPath: input.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return [] }
        defer { try? fm.removeItem(at: input) }
        guard let handle = try? FileHandle(forReadingFrom: input) else { return [] }
        defer { try? handle.close() }
        let result = try? await Subprocess.run(executableURL: URL(fileURLWithPath: node),
            arguments: [helper.path, engine, path] + engineArguments, timeout: 15, inputFile: handle)
        guard let result, result.terminationStatus == 0 else { return [] }
        return (try? JSONDecoder().decode([ProjectSemanticToken].self, from: result.standardOutput)) ?? []
    }
}
