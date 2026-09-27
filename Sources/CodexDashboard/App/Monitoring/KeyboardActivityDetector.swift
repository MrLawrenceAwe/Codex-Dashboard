import CoreGraphics
import Foundation

protocol KeyboardActivityDetecting {
    var hasRecentKeyboardActivity: Bool { get }
}

struct SystemKeyboardActivityDetector: KeyboardActivityDetecting {
    private let quietPeriod: TimeInterval

    init(quietPeriod: TimeInterval = 1.5) {
        self.quietPeriod = quietPeriod
    }

    var hasRecentKeyboardActivity: Bool {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .keyDown
        ) < quietPeriod
    }
}
