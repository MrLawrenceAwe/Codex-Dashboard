import AppKit

/// A menu-hosted action that does not end menu tracking when activated.
///
/// AppKit closes a menu after dispatching a regular `NSMenuItem` action. Refresh
/// actions use this view so their progress and result can be shown in the menu
/// without making the user reopen it.
@MainActor
final class PersistentMenuActionView: NSView {
    private static let rowHeight: CGFloat = 22
    private static let minimumWidth: CGFloat = 220

    private let titleLabel: NSTextField
    private let action: @MainActor () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateAppearance()
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovered = false }
            updateAppearance()
            setAccessibilityEnabled(isEnabled)
        }
    }

    init(
        title: String,
        indentationLevel: Int = 0,
        isEnabled: Bool,
        action: @escaping @MainActor () -> Void
    ) {
        titleLabel = NSTextField(labelWithString: title)
        self.isEnabled = isEnabled
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.rowHeight))

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18 + CGFloat(indentationLevel * 18)),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityEnabled(isEnabled)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.minimumWidth, height: Self.rowHeight)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isEnabled
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        // Consume the click inside the hosted view so NSMenu does not dispatch a
        // regular menu-item action and end menu tracking.
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.keyCode == 36 || event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }
        action()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }

    private func updateAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isHovered
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = if !isEnabled {
            .disabledControlTextColor
        } else if isHovered {
            .selectedMenuItemTextColor
        } else {
            .controlTextColor
        }
    }
}
