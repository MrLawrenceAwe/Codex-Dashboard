import XCTest

@testable import CodexDashboard

final class InjectionBundleTests: XCTestCase {
    func testMissingManifestReportsMissingResources() throws {
        try withResourceBundle { bundle, _ in
            XCTAssertThrowsError(try InjectionBundle.load(bundle: bundle)) { error in
                guard case DashboardError.missingResources = error else {
                    return XCTFail("Expected missing resources, got \(error)")
                }
            }
        }
    }

    func testMalformedManifestReportsPathAndDecodingReason() throws {
        for contents in ["not JSON", #"{"scripts":[],"stylesheets":[]}"#] {
            try withResourceBundle { bundle, manifestURL in
                try Data(contents.utf8).write(to: manifestURL)
                XCTAssertThrowsError(try InjectionBundle.load(bundle: bundle)) { error in
                    guard case DashboardError.invalidResourceManifest(let path, let reason) = error else {
                        return XCTFail("Expected invalid manifest, got \(error)")
                    }
                    XCTAssertEqual(path, manifestURL.path)
                    XCTAssertFalse(reason.isEmpty)
                    XCTAssertTrue(error.localizedDescription.contains(path))
                    XCTAssertTrue(error.localizedDescription.contains(reason))
                    if contents.hasPrefix("{") {
                        XCTAssertTrue(reason.contains("contracts"), "Keep the missing field in the diagnosis")
                    }
                }
            }
        }
    }

    func testUnreadableManifestReportsPathAndReadReason() throws {
        try withResourceBundle { bundle, manifestURL in
            try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
            XCTAssertThrowsError(try InjectionBundle.load(bundle: bundle)) { error in
                guard case DashboardError.unreadableResourceManifest(let path, let reason) = error else {
                    return XCTFail("Expected unreadable manifest, got \(error)")
                }
                XCTAssertEqual(path, manifestURL.path)
                XCTAssertFalse(reason.isEmpty)
                XCTAssertTrue(error.localizedDescription.contains(path))
                XCTAssertTrue(error.localizedDescription.contains(reason))
            }
        }
    }

    private func withResourceBundle(_ test: (Bundle, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
        let resources = root.appendingPathComponent("Contents/Resources/Dashboard")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "local.codex-dashboard.tests.\(UUID().uuidString)",
                    "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        try test(bundle, resources.appendingPathComponent("injection-manifest.json"))
    }

    func testPromptSchemaAndContractAreIncludedInInjection() throws {
        let injection = try InjectionBundle.load()
        let expectedVersion = #""version":\#(PromptLibrarySchema.currentVersion)"#

        XCTAssertTrue(injection.mountExpression.contains("const COMPOSER_PRESET_SCHEMA"))
        XCTAssertTrue(injection.mountExpression.contains("const PROMPT_LIBRARY_SCHEMA"))
        XCTAssertTrue(injection.mountExpression.contains(expectedVersion))
        XCTAssertTrue(injection.mountExpression.contains("const composerPresets"))
        XCTAssertTrue(injection.mountExpression.contains("const promptLibraryContract"))
    }

    func testSchemaOnlyChangeInvalidatesInjectionVersion() throws {
        let originalSchema = PromptLibrarySchema.javascriptDeclaration
        let updatedSchema = originalSchema.replacingOccurrences(of: "General", with: "Default")
        let original = try InjectionBundle.assemble(
            script: "return true;", stylesheet: "body {}", schemaDeclaration: originalSchema
        )
        let updated = try InjectionBundle.assemble(
            script: "return true;", stylesheet: "body {}", schemaDeclaration: updatedSchema
        )

        XCTAssertNotEqual(original.version, updated.version)
        XCTAssertTrue(updated.mountExpression.contains(updatedSchema))
        XCTAssertTrue(updated.healthCheckExpression.contains(updated.version))
    }

    func testManifestDefinesRendererContractResources() throws {
        let contract = try InjectionBundle.loadRendererContractSource()

        XCTAssertTrue(contract.contains("const dashboardElements"))
        XCTAssertTrue(contract.contains("const domUtils"))
        XCTAssertTrue(contract.contains("const codexUIContracts"))
    }
}
