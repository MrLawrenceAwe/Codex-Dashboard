import CryptoKit
import DashboardKeychain
import Darwin
import Foundation
import Security

// Only the Dashboard signed with this helper's certificate can call it.
// Never accept credentials, arbitrary service names, or account IDs on argv.
func authorizedParent() -> Bool {
    let parentPID = getppid()
    var ownCode: SecCode?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
        let values = info as? [String: Any],
        let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
        let certificate = certificates.first else { return false }
    let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02x", $0) }.joined()
    let expression = "identifier \"local.lawrenceawe.codex-dashboard\" and certificate leaf = H\"\(fingerprint)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess else { return false }
    var parentCode: SecCode?
    let attributes = [kSecGuestAttributePid as String: parentPID] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parentCode) == errSecSuccess,
        let parentCode else { return false }
    return SecCodeCheckValidity(parentCode, [], requirement) == errSecSuccess && getppid() == parentPID
}

struct Request: Decodable {
    let operation: String
    let accountID: UUID
    let credential: Data?
    let interactionAllowed: Bool
    let probe: Bool?
}
struct Response: Encodable {
    var status: OSStatus = errSecSuccess
    var authorizationRequired = false
    var credential: Data?
}

guard authorizedParent() else { exit(77) }
var response = Response()
do {
    let input = try FileHandle.standardInput.readToEnd() ?? Data()
    guard input.count <= 1_048_576 else { exit(64) }
    let request = try JSONDecoder().decode(Request.self, from: input)
    let vault = NativeAccountCredentialVault(probe: request.probe == true)
    switch request.operation {
    case "read":
        response.credential = try request.interactionAllowed
            ? vault.credential(for: request.accountID)
            : vault.credentialWithoutUserInteraction(for: request.accountID)
    case "store":
        guard let credential = request.credential else { exit(64) }
        if request.interactionAllowed { try vault.store(credential, for: request.accountID) }
        else { try vault.storeWithoutUserInteraction(credential, for: request.accountID) }
    case "delete":
        // Deletion must also honor the no-interaction policy.
        guard request.interactionAllowed else { exit(64) }
        try vault.deleteCredential(for: request.accountID)
    default: exit(64)
    }
} catch KeychainVaultError.authorizationRequired {
    response.authorizationRequired = true
} catch KeychainVaultError.status(let status) {
    response.status = status
} catch {
    response.status = errSecParam
}
try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
