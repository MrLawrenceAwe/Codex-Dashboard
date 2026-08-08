import CryptoKit
import Foundation

struct DashboardAdapter: Sendable {
    let expression: String

    static func load(bundle: Bundle? = nil) throws -> DashboardAdapter {
        let resourceBundle = bundle ?? defaultResourceBundle
        guard
            let scriptURL = resourceBundle.url(
                forResource: "dashboard",
                withExtension: "js",
                subdirectory: "Dashboard"
            ),
            let cssURL = resourceBundle.url(
                forResource: "dashboard",
                withExtension: "css",
                subdirectory: "Dashboard"
            )
        else {
            throw DashboardError.missingResources
        }

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let stylesheet = try String(contentsOf: cssURL, encoding: .utf8)
        let digest = SHA256.hash(data: Data((script + stylesheet).utf8))
        let version = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let cssData = try JSONSerialization.data(withJSONObject: stylesheet, options: .fragmentsAllowed)
        guard let encodedCSS = String(data: cssData, encoding: .utf8) else {
            throw DashboardError.missingResources
        }
        let expression = """
        (() => {
          const DASHBOARD_VERSION = \(String(reflecting: version));
          const DASHBOARD_CSS = \(encodedCSS);
          \(script)
        })()
        """
        return DashboardAdapter(expression: expression)
    }

    private static var defaultResourceBundle: Bundle {
        if Bundle.main.url(
            forResource: "dashboard",
            withExtension: "js",
            subdirectory: "Dashboard"
        ) != nil {
            return .main
        }
        return .module
    }
}
