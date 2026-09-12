import Foundation

protocol NtfyPublishing: Sendable {
    func publish(topic: String, title: String, message: String) async throws
}

enum NtfyPublishError: LocalizedError {
    case invalidResponse
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "ntfy returned an invalid response."
        case .rejected(let statusCode):
            return "ntfy rejected the notification (HTTP \(statusCode))."
        }
    }
}

struct NtfyPublisher: NtfyPublishing {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func publish(topic: String, title: String, message: String) async throws {
        guard let url = URL(string: "https://ntfy.sh/\(topic)") else {
            throw NtfyPublishError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(message.utf8)
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.setValue("default", forHTTPHeaderField: "X-Priority")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NtfyPublishError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NtfyPublishError.rejected(response.statusCode)
        }
    }
}

