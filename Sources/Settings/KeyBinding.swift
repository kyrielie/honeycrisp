import AppKit

// MARK: - RebindableAction

enum RebindableAction: String, CaseIterable, Codable {
    case openFile, searchInBook, showTOC, toggleFloat, toggleReadingMode

    var displayName: String {
        switch self {
        case .openFile: "Open File"
        case .searchInBook: "Search in Book"
        case .showTOC: "Show Table of Contents"
        case .toggleFloat: "Float on Top"
        case .toggleReadingMode: "Toggle Paginated Mode"
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .openFile: KeyBinding(key: "o", modifiers: [.command])
        case .searchInBook: KeyBinding(key: "f", modifiers: [.command])
        case .showTOC: KeyBinding(key: "t", modifiers: [.command])
        case .toggleFloat: KeyBinding(key: "t", modifiers: [.command, .shift])
        case .toggleReadingMode: KeyBinding(key: "p", modifiers: [.command, .shift])
        }
    }
}

// MARK: - KeyBinding

struct KeyBinding: Codable, Equatable, Hashable {
    var key: String                              // NSEvent.charactersIgnoringModifiers, lowercased
    var modifiers: NSEvent.ModifierFlags.RawValue // stored raw — ModifierFlags itself isn't Codable

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers.rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Only the modifier keys this app's shortcuts actually use — masks out flags
    /// like .numericPad/.function that NSEvent sets incidentally and that would
    /// otherwise make two visually-identical bindings compare unequal.
    private static let relevantMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    static func == (lhs: KeyBinding, rhs: KeyBinding) -> Bool {
        lhs.key == rhs.key
            && (lhs.modifierFlags.intersection(relevantMask)) == (rhs.modifierFlags.intersection(relevantMask))
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifierFlags.intersection(Self.relevantMask).rawValue)
    }

    /// Symbolic display string, e.g. "⇧⌘P".
    var displayString: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += key.uppercased()
        return s
    }
}

// MARK: - SettingsManager.keyBindings

extension SettingsManager {
    /// JSON-in-UserDefaults, same "don't let old data silently break new fields"
    /// concern as Patch 0005's HistoryEntry decoding: any action missing from
    /// stored data (new app version, or corrupted/partial save) defaults to
    /// action.defaultBinding rather than being silently absent.
    var keyBindings: [RebindableAction: KeyBinding] {
        get {
            var result: [RebindableAction: KeyBinding] = [:]
            let stored: [String: KeyBinding]
            if let data = UserDefaults.standard.data(forKey: "readerKeyBindings"),
               let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
                stored = decoded
            } else {
                stored = [:]
            }
            for action in RebindableAction.allCases {
                result[action] = stored[action.rawValue] ?? action.defaultBinding
            }
            return result
        }
        set {
            var raw: [String: KeyBinding] = [:]
            for (action, binding) in newValue { raw[action.rawValue] = binding }
            if let data = try? JSONEncoder().encode(raw) {
                UserDefaults.standard.set(data, forKey: "readerKeyBindings")
            }
            NotificationCenter.default.post(name: .keyBindingsChanged, object: nil)
        }
    }

    /// Sets a single action's binding, leaving the rest of the stored map
    /// untouched. Preferred over `keyBindings[action] = binding` at call sites,
    /// since the latter round-trips the entire dictionary through the getter
    /// (which fills in defaults for every other action) before writing it back —
    /// harmless, but this is clearer about intent.
    func setKeyBinding(_ binding: KeyBinding, for action: RebindableAction) {
        var all = keyBindings
        all[action] = binding
        keyBindings = all
    }

    /// Reserved combos, hard-blocked from assignment regardless of what's
    /// currently wired to a menu item.
    func isReserved(_ binding: KeyBinding) -> Bool {
        let reserved: Set<KeyBinding> = [
            KeyBinding(key: "q", modifiers: [.command]),
            KeyBinding(key: ",", modifiers: [.command]),
            KeyBinding(key: "w", modifiers: [.command]),
            KeyBinding(key: "h", modifiers: [.command]),
            KeyBinding(key: "m", modifiers: [.command]),
            KeyBinding(key: "c", modifiers: [.command]),
            KeyBinding(key: "v", modifiers: [.command]),
            KeyBinding(key: "x", modifiers: [.command]),
            KeyBinding(key: "z", modifiers: [.command]),
            KeyBinding(key: "a", modifiers: [.command]),
        ]
        return reserved.contains(binding)
    }

    /// The action currently bound to `binding`, if any (excluding nothing —
    /// callers compare the result against the action being rebound themselves,
    /// same as the plan's recorder-UI usage).
    func action(boundTo binding: KeyBinding) -> RebindableAction? {
        keyBindings.first(where: { $0.value == binding })?.key
    }
}

extension Notification.Name {
    /// Posted whenever keyBindings changes, so AppDelegate can re-walk
    /// NSApp.mainMenu and update keyEquivalent/keyEquivalentModifierMask live.
    static let keyBindingsChanged = Notification.Name("keyBindingsChanged")
}
