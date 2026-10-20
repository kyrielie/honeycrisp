import AppKit

/// A slider with an editable number field and a nudge stepper, kept in sync. Replaces bare steppers in the
/// Appearance tab: a stepper alone is a tiny click target and needs dozens of clicks across wide ranges.
///
/// - The slider and stepper snap to `Spec.step` counted from the lower bound; typed values are only clamped
///   and rounded to `Spec.fractionDigits`.
/// - `commitsOnRelease` is for settings that re-render the book (max width, margins): the display follows
///   the drag, but `onChange` fires once when the mouse is released.
/// - Other settings forward during a drag, at most every `liveInterval` seconds, and always forward the
///   final value.
/// - `setValue(_:)` updates the display without calling `onChange`.
final class ValueSliderControl: NSStackView, NSTextFieldDelegate {
    struct Spec {
        let range: ClosedRange<Double>
        let step: Double
        let fractionDigits: Int
        let accessibilityName: String
        let format: (Double) -> String
    }

    var onChange: ((Double) -> Void)?

    /// Shown in the field instead of the value while the control is disabled (for example "Book").
    var disabledText: String? {
        didSet { updateViews() }
    }

    var isEnabled: Bool = true {
        didSet {
            slider.isEnabled = isEnabled
            field.isEnabled = isEnabled
            stepper.isEnabled = isEnabled
            updateViews()
        }
    }

    private(set) var value: Double

    private let spec: Spec
    private let commitsOnRelease: Bool
    private let slider = NSSlider()
    private let field = NSTextField()
    private let stepper = NSStepper()
    private var lastForwarded: Double
    private var lastLiveForward = Date.distantPast
    private static let liveInterval: TimeInterval = 0.05

    init(spec: Spec, value: Double, commitsOnRelease: Bool) {
        self.spec = spec
        self.commitsOnRelease = commitsOnRelease
        let initial = Self.clamp(value, to: spec.range)
        self.value = initial
        self.lastForwarded = initial
        super.init(frame: .zero)
        configure()
        updateViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Pure helpers (unit tested)

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func roundedToDigits(_ value: Double, fractionDigits: Int) -> Double {
        let factor = pow(10.0, Double(max(0, fractionDigits)))
        return (value * factor).rounded() / factor
    }

    /// Nearest step counted from the lower bound, rounded to `fractionDigits`, then clamped.
    static func snap(_ value: Double, range: ClosedRange<Double>, step: Double, fractionDigits: Int) -> Double {
        guard value.isFinite, step > 0 else { return range.lowerBound }
        let steps = ((value - range.lowerBound) / step).rounded()
        let snapped = roundedToDigits(range.lowerBound + steps * step, fractionDigits: fractionDigits)
        return clamp(snapped, to: range)
    }

    // MARK: Public

    func setValue(_ newValue: Double) {
        value = Self.clamp(newValue, to: spec.range)
        lastForwarded = value
        updateViews()
    }

    // MARK: Setup

    private func configure() {
        orientation = .horizontal
        spacing = 6
        alignment = .centerY

        slider.minValue = spec.range.lowerBound
        slider.maxValue = spec.range.upperBound
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.setAccessibilityLabel(spec.accessibilityName)
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.delegate = self
        field.setAccessibilityLabel("\(spec.accessibilityName) value")
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true

        stepper.minValue = spec.range.lowerBound
        stepper.maxValue = spec.range.upperBound
        stepper.increment = spec.step
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperNudged(_:))
        stepper.setAccessibilityLabel("\(spec.accessibilityName) step")

        addArrangedSubview(slider)
        addArrangedSubview(field)
        addArrangedSubview(stepper)
    }

    private func updateViews() {
        slider.doubleValue = value
        stepper.doubleValue = value
        let text = spec.format(value)
        field.stringValue = (!isEnabled ? disabledText : nil) ?? text
        slider.setAccessibilityValueDescription(text)
        stepper.setAccessibilityValueDescription(text)
    }

    // MARK: Actions

    @objc private func sliderMoved(_ sender: NSSlider) {
        let snapped = Self.snap(
            sender.doubleValue, range: spec.range, step: spec.step, fractionDigits: spec.fractionDigits)
        value = snapped
        updateViews()

        let eventType = NSApp.currentEvent?.type
        let dragInProgress = eventType == .leftMouseDown || eventType == .leftMouseDragged
        if dragInProgress {
            guard !commitsOnRelease else { return }
            let now = Date()
            guard now.timeIntervalSince(lastLiveForward) >= Self.liveInterval else { return }
            lastLiveForward = now
        }
        forwardIfChanged()
    }

    @objc private func stepperNudged(_ sender: NSStepper) {
        commit(sender.doubleValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let parsed = SettingsValueFormat.parseNumber(field.stringValue) else {
            updateViews()
            return
        }
        commit(parsed)
    }

    private func commit(_ newValue: Double) {
        value = Self.roundedToDigits(Self.clamp(newValue, to: spec.range), fractionDigits: spec.fractionDigits)
        updateViews()
        forwardIfChanged()
    }

    private func forwardIfChanged() {
        guard value != lastForwarded else { return }
        lastForwarded = value
        onChange?(value)
    }
}
