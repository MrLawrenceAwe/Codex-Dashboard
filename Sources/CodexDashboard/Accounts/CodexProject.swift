import Foundation

struct CodexProject: Codable, Equatable, Sendable {
    struct Root: Codable, Equatable, Sendable { let path: String }
    let id: String
    let name: String
    let roots: [Root]
    var metadata: [String: String] = [:]
}

