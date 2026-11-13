import AppKit

/// Shared neutral surfaces keep the native code view and SwiftUI chrome continuous.
enum ProjectViewerAppearance {
    static func background(dark: Bool) -> NSColor {
        NSColor(white: dark ? 0.125 : 1, alpha: 1)
    }

    static func sidebar(dark: Bool) -> NSColor {
        NSColor(white: dark ? 0.105 : 0.97, alpha: 1)
    }
}
