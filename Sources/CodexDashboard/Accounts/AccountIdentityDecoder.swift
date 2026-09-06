import Foundation

struct AccountIdentity {
    let identifier: String
    let displayName: String?
    let email: String?

    var accountName: String {
        Self.nonempty(displayName)
            ?? Self.nonempty(email)
            ?? identifier
    }

    private static func nonempty(_ value: String?) -> String? {
        let words = (value ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let normalized = words.joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

enum AccountIdentityDecoder {
    static func identity(in credential: Data) -> AccountIdentity? {
        guard
            let object = try? JSONSerialization.jsonObject(with: credential),
            let root = object as? [String: Any],
            let tokens = root["tokens"] as? [String: Any]
        else { return nil }
        let directAccountID = tokens["account_id"] as? String
        guard let idToken = tokens["id_token"] as? String else {
            return identity(identifier: directAccountID)
        }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return identity(identifier: directAccountID) }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard
            let payloadData = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
            let authentication = claims["https://api.openai.com/auth"] as? [String: Any]
        else { return identity(identifier: directAccountID) }
        let accountID = directAccountID ?? authentication["chatgpt_account_id"] as? String
        guard let accountID, !accountID.isEmpty else { return nil }
        return AccountIdentity(
            identifier: accountID,
            displayName: claims["name"] as? String,
            email: claims["email"] as? String
        )
    }

    static func accountName(_ accountName: String, matches displayName: String) -> Bool {
        let accountWords = normalizedWords(in: accountName)
        let displayWords = normalizedWords(in: displayName)
        guard !accountWords.isEmpty, !displayWords.isEmpty else { return false }
        return accountWords == displayWords
            || (accountWords.count == 1 && displayWords.contains(accountWords[0]))
    }

    private static func identity(identifier: String?) -> AccountIdentity? {
        identifier.flatMap {
            $0.isEmpty
                ? nil
                : AccountIdentity(identifier: $0, displayName: nil, email: nil)
        }
    }

    private static func normalizedWords(in value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
