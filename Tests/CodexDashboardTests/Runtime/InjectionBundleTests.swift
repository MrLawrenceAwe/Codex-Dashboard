import XCTest

@testable import CodexDashboard

final class InjectionBundleTests: XCTestCase {
    func testPromptSchemaIsIncludedInInjectionAndPromptContract() throws {
        let injection = try InjectionBundle.load()
        let contract = try InjectionBundle.loadPromptLibraryContractSource()
        let expectedVersion = #""version":\#(PromptLibrarySchema.currentVersion)"#

        XCTAssertTrue(injection.mountExpression.contains("const PROMPT_LIBRARY_SCHEMA"))
        XCTAssertTrue(injection.mountExpression.contains(expectedVersion))
        XCTAssertTrue(contract.contains("const PROMPT_LIBRARY_SCHEMA"))
        XCTAssertTrue(contract.contains(expectedVersion))
        XCTAssertTrue(contract.contains("const promptLibraryContract"))
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
