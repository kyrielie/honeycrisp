// SearchBarViewController.swift
// In-book text search overlay

import AppKit
import WebKit

protocol SearchBarDelegate: AnyObject {
    func searchBar(_ bar: SearchBarViewController, didSearch term: String)
    func searchBarDidRequestNext(_ bar: SearchBarViewController)
    func searchBarDidRequestPrevious(_ bar: SearchBarViewController)
    func searchBarDidDismiss(_ bar: SearchBarViewController)
}

final class SearchBarViewController: NSViewController {

    weak var delegate: SearchBarDelegate?

    private var searchField: NSSearchField!
    private var resultLabel: NSTextField!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var closeButton: NSButton!

    var resultCount: Int = 0 {
        didSet {
            let text = resultCount == 0 ? "No results" : "\(resultCount) found"
            resultLabel.stringValue = text
            resultLabel.textColor = resultCount == 0 ? .systemRed : .secondaryLabelColor
            prevButton.isEnabled = resultCount > 0
            nextButton.isEnabled = resultCount > 0
        }
    }

    override func loadView() {
        // Pill-shaped container
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 44))
        root.material = .hudWindow
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true

        // Subtle border
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        root.layer?.borderWidth = 0.5

        searchField = NSSearchField()
        searchField.placeholderString = "Search in book…"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        root.addSubview(searchField)

        resultLabel = NSTextField(labelWithString: "")
        resultLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(resultLabel)

        prevButton = makeIconButton(symbol: "chevron.up", tip: "Previous result", action: #selector(prevTapped))
        nextButton = makeIconButton(symbol: "chevron.down", tip: "Next result", action: #selector(nextTapped))
        closeButton = makeIconButton(symbol: "xmark", tip: "Close search", action: #selector(closeTapped))

        prevButton.isEnabled = false
        nextButton.isEnabled = false

        [prevButton, nextButton, closeButton].forEach { root.addSubview($0!) }

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 180),

            resultLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            resultLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            resultLabel.widthAnchor.constraint(equalToConstant: 70),

            prevButton.leadingAnchor.constraint(equalTo: resultLabel.trailingAnchor, constant: 4),
            prevButton.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 28),
            prevButton.heightAnchor.constraint(equalToConstant: 28),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 28),
            nextButton.heightAnchor.constraint(equalToConstant: 28),

            closeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Public

    func clear() {
        searchField.stringValue = ""
        resultCount = 0
        resultLabel.stringValue = ""
    }

    // MARK: - Actions

    @objc private func prevTapped() { delegate?.searchBarDidRequestPrevious(self) }
    @objc private func nextTapped() { delegate?.searchBarDidRequestNext(self) }
    @objc private func closeTapped() { delegate?.searchBarDidDismiss(self) }

    // MARK: - Helpers

    private func makeIconButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
        let btn = NSButton(image: img, target: self, action: action)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.toolTip = tip
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }
}

// MARK: - NSSearchFieldDelegate

extension SearchBarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        delegate?.searchBar(self, didSearch: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            delegate?.searchBarDidRequestNext(self)
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            delegate?.searchBarDidDismiss(self)
            return true
        }
        return false
    }
}
