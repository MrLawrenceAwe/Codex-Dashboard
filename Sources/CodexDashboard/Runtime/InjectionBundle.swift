import CryptoKit
import Foundation

struct InjectionBundle: Sendable {
    private struct ResourceManifest: Decodable {
        let scripts: [String]
        let stylesheets: [String]
    }

    let version: String
    let mountExpression: String

    var healthCheckExpression: String {
        """
        (() => Boolean(
          window.__codexDashboard?.version === \(String(reflecting: version))
            && typeof window.__codexDashboard?.applySnapshot === 'function'
            && window.__codexDashboard.ensureMounted?.()
        ))()
        """
    }

    static func load(bundle: Bundle? = nil) throws -> InjectionBundle {
        let resourceBundle = bundle ?? defaultResourceBundle
        let manifest = try loadManifest(from: resourceBundle)
        let script = try loadResources(
            named: manifest.scripts,
            withExtension: "js",
            from: resourceBundle
        )
        let stylesheet = try loadResources(
            named: manifest.stylesheets,
            withExtension: "css",
            from: resourceBundle
        )
        let digest = SHA256.hash(data: Data((script + stylesheet).utf8))
        let version = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let cssData = try JSONSerialization.data(withJSONObject: stylesheet, options: .fragmentsAllowed)
        guard let encodedCSS = String(data: cssData, encoding: .utf8) else {
            throw DashboardError.missingResources
        }
        let mountExpression = """
        (() => {
          const DASHBOARD_VERSION = \(String(reflecting: version));
          const DASHBOARD_CSS = \(encodedCSS);
          \(script)
        })()
        """
        return InjectionBundle(version: version, mountExpression: mountExpression)
    }

    static func loadRendererContractSource(bundle: Bundle? = nil) throws -> String {
        try loadResources(
            named: ["Core/dom-utils", "Core/codex-ui-contracts"],
            withExtension: "js",
            from: bundle ?? defaultResourceBundle
        )
    }

    static func loadPromptLibraryContractSource(bundle: Bundle? = nil) throws -> String {
        try loadResources(
            named: ["Prompts/prompt-library-contract"],
            withExtension: "js",
            from: bundle ?? defaultResourceBundle
        )
    }

    private static func loadManifest(from bundle: Bundle) throws -> ResourceManifest {
        guard let url = bundle.url(
            forResource: "injection-manifest",
            withExtension: "json",
            subdirectory: "Dashboard"
        ) else {
            throw DashboardError.missingResources
        }
        do {
            return try JSONDecoder().decode(ResourceManifest.self, from: Data(contentsOf: url))
        } catch {
            throw DashboardError.missingResources
        }
    }

    private static func loadResources(
        named names: [String],
        withExtension resourceExtension: String,
        from bundle: Bundle
    ) throws -> String {
        try names.map { name in
            let path = name as NSString
            let directory = path.deletingLastPathComponent
            let subdirectory = directory == "."
                ? "Dashboard"
                : "Dashboard/\(directory)"
            guard let url = bundle.url(
                forResource: path.lastPathComponent,
                withExtension: resourceExtension,
                subdirectory: subdirectory
            ) else {
                throw DashboardError.missingResources
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
    }

    private static var defaultResourceBundle: Bundle {
        if Bundle.main.url(
            forResource: "injection-manifest",
            withExtension: "json",
            subdirectory: "Dashboard"
        ) != nil {
            return .main
        }
        return .module
    }
}
