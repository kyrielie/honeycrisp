//
//  FanfictionSettingsViewController.swift
//  Honeycrisp
//
//  Created on 2026-10-23.
//

import AppKit

// MARK: - FanfictionSettingsViewController

final class FanfictionSettingsViewController: NSViewController, SettingsPaneSizing {

    var preferredPaneSize: NSSize?
    let isResizableView = false

    private weak var formatCheckbox: NSButton?
    private weak var indentCheckbox: NSButton?
    private weak var spacerCheckbox: NSButton?

    // swiftlint:disable:next function_body_length
    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsPaneMetrics.size))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(
            wrappingLabelWithString:
                "Formatting rules and clean-up options tailored for webfiction, fanfiction, and Calibre-converted books."
        )
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)
        stack.setCustomSpacing(14, after: intro)

        // 1. Format for AO3
        let formatCheckbox = NSButton(
            checkboxWithTitle: "Format for AO3 (Archive of Our Own)",
            target: self,
            action: #selector(toggleFormatForAO3(_:))
        )
        formatCheckbox.state = SettingsManager.shared.formatFirstChapter ? .on : .off
        stack.addArrangedSubview(formatCheckbox)
        self.formatCheckbox = formatCheckbox

        let hint = NSTextField(
            wrappingLabelWithString:
                "Removes redundant table-of-contents banners and optimizes calibre2 title metadata across chapters."
        )
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(14, after: hint)

        // 2. Strip leading whitespace used as indents
        let indentCheckbox = NSButton(
            checkboxWithTitle: "Strip leading whitespace used as indents",
            target: self,
            action: #selector(toggleRemoveParagraphIndents(_:))
        )
        indentCheckbox.state = SettingsManager.shared.removeParagraphIndents ? .on : .off
        stack.addArrangedSubview(indentCheckbox)
        self.indentCheckbox = indentCheckbox

        let indentHint = NSTextField(
            wrappingLabelWithString:
                "Removes literal spaces some converters use for indentation. First-line indent in Appearance controls the actual gap."
        )
        indentHint.font = NSFont.systemFont(ofSize: 11)
        indentHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indentHint)
        stack.setCustomSpacing(14, after: indentHint)

        // 3. Collapse empty spacer paragraphs
        let spacerCheckbox = NSButton(
            checkboxWithTitle: "Collapse empty spacer paragraphs",
            target: self,
            action: #selector(toggleCollapseSpacerParagraphs(_:))
        )
        spacerCheckbox.state = SettingsManager.shared.collapseSpacerParagraphs ? .on : .off
        stack.addArrangedSubview(spacerCheckbox)
        self.spacerCheckbox = spacerCheckbox

        let spacerHint = NSTextField(
            wrappingLabelWithString:
                "Collapses empty blank paragraphs inserted by converters, allowing Paragraph Spacing in Appearance to dictate layout."
        )
        spacerHint.font = NSFont.systemFont(ofSize: 11)
        spacerHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(spacerHint)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        ])

        self.view = root
        resolvePreferredPaneSize()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        formatCheckbox?.state = SettingsManager.shared.formatFirstChapter ? .on : .off
        indentCheckbox?.state = SettingsManager.shared.removeParagraphIndents ? .on : .off
        spacerCheckbox?.state = SettingsManager.shared.collapseSpacerParagraphs ? .on : .off
    }

    @objc private func toggleFormatForAO3(_ sender: NSButton) {
        SettingsManager.shared.formatFirstChapter = sender.state == .on
    }

    @objc private func toggleRemoveParagraphIndents(_ sender: NSButton) {
        SettingsManager.shared.removeParagraphIndents = sender.state == .on
    }

    @objc private func toggleCollapseSpacerParagraphs(_ sender: NSButton) {
        SettingsManager.shared.collapseSpacerParagraphs = sender.state == .on
    }
}
