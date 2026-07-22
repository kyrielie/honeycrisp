import AppKit

// MARK: - ShortcutsSettingsViewController

final class ShortcutsSettingsViewController: NSViewController {

    private var conflictLabel: NSTextField!
    private var recorders: [RebindableAction: RecorderButton] = [:]

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])

        for action in RebindableAction.allCases {
            stack.addArrangedSubview(makeRow(for: action))
        }

        conflictLabel = NSTextField(labelWithString: "")
        conflictLabel.font = NSFont.systemFont(ofSize: 11)
        conflictLabel.textColor = .systemRed
        conflictLabel.isHidden = true
        stack.addArrangedSubview(conflictLabel)

        view = root
    }

    private func makeRow(for action: RebindableAction) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let label = NSTextField(labelWithString: action.displayName)
        label.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let recorder = RecorderButton()
        recorder.updateTitle(binding: SettingsManager.shared.keyBindings[action])
        recorder.onRecord = { [weak self] newBinding in
            self?.attemptRebind(action: action, to: newBinding, recorder: recorder)
        }
        recorders[action] = recorder

        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetBinding(_:)))
        resetButton.bezelStyle = .rounded
        resetButton.identifier = NSUserInterfaceItemIdentifier(action.rawValue)

        row.addArrangedSubview(label)
        row.addArrangedSubview(recorder)
        row.addArrangedSubview(resetButton)
        return row
    }

    /// Ported from the plan's spec: reject a reserved combo or a collision with
    /// another action's current binding, surfaced inline rather than silently
    /// overwriting either the reserved shortcut or the other action's binding.
    private func attemptRebind(action: RebindableAction, to newBinding: KeyBinding, recorder: RecorderButton) {
        guard !SettingsManager.shared.isReserved(newBinding) else {
            showConflict("That shortcut is reserved by the system.")
            recorder.updateTitle(binding: SettingsManager.shared.keyBindings[action])
            return
        }
        if let conflict = SettingsManager.shared.action(boundTo: newBinding), conflict != action {
            showConflict("Already used by \"\(conflict.displayName)\".")
            recorder.updateTitle(binding: SettingsManager.shared.keyBindings[action])
            return
        }
        conflictLabel.isHidden = true
        SettingsManager.shared.setKeyBinding(newBinding, for: action)
        recorder.updateTitle(binding: newBinding)
    }

    private func showConflict(_ message: String) {
        conflictLabel.stringValue = message
        conflictLabel.isHidden = false
    }

    @objc private func resetBinding(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = RebindableAction(rawValue: raw) else { return }
        SettingsManager.shared.setKeyBinding(action.defaultBinding, for: action)
        recorders[action]?.updateTitle(binding: action.defaultBinding)
        conflictLabel.isHidden = true
    }
}

// MARK: - RecorderButton
//
// Ported from Ambrosia's RecorderButton (PreferencesWindowController.swift) — a
// raw NSButton subclass with a local NSEvent monitor that captures the next
// keyDown while focused and renders it as a symbolic string (⌘⇧P etc.). Adapted
// to Honeycrisp's KeyBinding(key:modifiers:) rather than Ambrosia's
// character/Set<ModifierKey> pair; otherwise essentially unchanged, embedded
// directly in an NSStackView row (Patch 0009) instead of a SwiftUI Form row.

final class RecorderButton: NSButton {
    var onRecord: ((KeyBinding) -> Void)?
    private var monitor: Any?
    private var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func updateTitle(binding: KeyBinding?) {
        guard !isRecording else { return }
        title = binding?.displayString ?? "Click to set"
    }

    @objc private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = "Recording…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.stopRecording(with: event)
            return nil
        }
    }

    private func stopRecording(with event: NSEvent) {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard let character = event.charactersIgnoringModifiers?.lowercased(), !character.isEmpty else {
            title = "Click to set"
            return
        }
        let binding = KeyBinding(key: character, modifiers: event.modifierFlags)
        onRecord?(binding)
    }
}
