import CryptoKit
import Foundation

struct DashboardInjection: Sendable {
    private static let scriptNames = [
        "bootstrap",
        "codex-ui",
        "prompt-library",
        "thread-dashboard",
    ]
    private static let stylesheetNames = ["dashboard", "prompts"]

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

    static func load(bundle: Bundle? = nil) throws -> DashboardInjection {
        let resourceBundle = bundle ?? defaultResourceBundle
        let script = try loadResources(
            named: scriptNames,
            withExtension: "js",
            from: resourceBundle
        )
        let stylesheet = try loadResources(
            named: stylesheetNames,
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
        return DashboardInjection(version: version, mountExpression: mountExpression)
    }

    private static func loadResources(
        named names: [String],
        withExtension resourceExtension: String,
        from bundle: Bundle
    ) throws -> String {
        try names.map { name in
            guard let url = bundle.url(
                forResource: name,
                withExtension: resourceExtension,
                subdirectory: "Dashboard"
            ) else {
                throw DashboardError.missingResources
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
    }

    private static var defaultResourceBundle: Bundle {
        if Bundle.main.url(
            forResource: scriptNames[0],
            withExtension: "js",
            subdirectory: "Dashboard"
        ) != nil {
            return .main
        }
        return .module
    }
}
