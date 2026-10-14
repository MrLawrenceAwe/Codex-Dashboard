import Foundation

/// Decodes payload claims for local identity lookup; does not verify signatures.
enum JWTClaimsDecoder {
    static func decodeUnverifiedClaims(_ token: String) throws -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
