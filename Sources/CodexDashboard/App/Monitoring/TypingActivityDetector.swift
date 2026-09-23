import CoreGraphics
import Foundation

protocol TypingActivityDetecting {
    var isUserTyping: Bool { get }
}

struct SystemTypingActivityDetector: TypingActivityDetecting {
    private let quietPeriod: TimeInterval

    init(quietPeriod: TimeInterval = 1.5) {
        self.quietPeriod = quietPeriod
    }

    var isUserTyping: Bool {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .keyDown
        ) < quietPeriod
    }
}
