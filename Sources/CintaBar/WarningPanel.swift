import AppKit

/// A warning that floats above every app: an icon, a title, a line or two of text and up to two
/// buttons, all of which can change while it's up.
///
/// It isn't an `NSAlert` because a modal alert holds the main run loop until it's answered, and
/// while this one is up the menu has to keep working, a countdown has to run and the treadmill
/// has to be heard. Nor does it wait for the app to be active: CintaBar is an agent, which macOS
/// may decline to bring forward, so the panel goes to the front and takes the keyboard without it.
final class WarningPanel: NSObject {
    typealias Button = (title: String, action: () -> Void)

    private let panel = NSPanel(
        contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered,
        defer: true)
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let buttonRow = NSStackView()
    private var buttons: [NSButton] = []
    private var actions: [() -> Void] = []

    private static let textWidth = 320.0

    override init() {
        super.init()
        let icon = NSImageView(image: NSImage(named: NSImage.cautionName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        textLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for label in [titleLabel, textLabel] {
            label.preferredMaxLayoutWidth = Self.textWidth
            label.isSelectable = false
        }

        let text = NSStackView(views: [titleLabel, textLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        let message = NSStackView(views: [icon, text])
        message.alignment = .top
        message.spacing = 16
        let content = NSStackView(views: [message, buttonRow])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            text.widthAnchor.constraint(equalToConstant: Self.textWidth),
        ])

        panel.contentView = content
        panel.title = "CintaBar"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .alertPanel
        // Above other apps' windows, in every space including a full-screen one, and still there
        // when another app is in front, which for an agent is nearly always.
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
    }

    var isVisible: Bool { panel.isVisible }

    /// Puts the warning up, or changes what it says if it's already there.
    ///
    /// - Parameter buttons: One or two. Return chooses the first, and nothing but a click the
    ///   second.
    /// - Returns: Whether it wasn't on screen before.
    @discardableResult
    func show(title: String, text: String, buttons: [Button]) -> Bool {
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        if textLabel.stringValue != text { textLabel.stringValue = text }
        // Buttons are only replaced when they change. A press under way on one that's replaced
        // would be lost, and the text changes every second.
        if self.buttons.map(\.title) != buttons.map(\.title) {
            self.buttons = buttons.indices.map { index in
                let button = NSButton(title: buttons[index].title, target: self, action: #selector(run(_:)))
                button.tag = index
                if index == 0 { button.keyEquivalent = "\r" }
                return button
            }
            // The default button goes last, as in an alert.
            buttonRow.setViews(self.buttons.reversed(), in: .leading)
        }
        actions = buttons.map(\.action)

        guard let content = panel.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        if content.frame.size != content.fittingSize { panel.setContentSize(content.fittingSize) }
        guard !panel.isVisible else { return false }
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
        // With keyboard navigation on, Space presses whichever button has the focus. Typing meant
        // for another app may land here, so that had better be the first one.
        panel.makeFirstResponder(self.buttons.first)
        return true
    }

    func close() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    @objc private func run(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
