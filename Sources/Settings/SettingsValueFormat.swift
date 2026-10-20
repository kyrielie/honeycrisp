import Foundation

/// Display strings and number parsing for the Appearance sliders. Pure so it is unit tested; the earlier
/// `%.2g` format kept two significant digits and showed 1.25 as "1.2" and 1.75 as "1.8".
enum SettingsValueFormat {
    /// Two decimals at most, one trailing zero trimmed: 1 -> "1.0", 1.25 -> "1.25", 0.5 -> "0.5".
    /// Non-finite input shows "0.0".
    private static func trimmed(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        var text = String(format: "%.2f", value)
        if text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func em(_ value: Double) -> String {
        "\(trimmed(value)) em"
    }

    static func lineHeight(_ value: Double) -> String {
        trimmed(value)
    }

    static func px(_ value: Double) -> String {
        guard value.isFinite else { return "0px" }
        return "\(Int(value.rounded()))px"
    }

    /// First number in a typed string, ignoring units and surrounding text ("700px" -> 700, "1,5" -> 1.5).
    /// Returns nil when there is no finite number.
    static func parseNumber(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Scanner(string: normalized).scanDouble(), value.isFinite else { return nil }
        return value
    }
}
