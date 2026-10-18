// SearchBarViewController.swift
// In-book text search overlay

import AppKit
import WebKit

protocol SearchBarDelegate: AnyObject {
    func searchBar(_ bar: SearchBarViewController, didSearch term: String)
    func searchBar(_ bar: SearchBarViewController, didSelect result: BookSearchResult)
    func searchBarDidRequestNext(_ bar: SearchBarViewController)
    func searchBarDidRequestPrevious(_ bar: SearchBarViewController)
    func searchBarDidDismiss(_ bar: SearchBarViewController)
}

final class SearchBarViewController: NSViewController {

    weak var delegate: SearchBarDelegate?
    var onExpandedChange: ((Bool) -> Void)?

    private var searchField: NSSearchField!
    private var resultLabel: NSTextField!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var closeButton: NSButton!
    private var resultsTable: NSTableView!
    private var results: [BookSearchResult] = []
    private var selectedResultIndex = -1
    private var expanded = false
    private var resultsScroll: NSScrollView!
    private var rootHeightConstraint: NSLayoutConstraint!
    private var resultsPanelConstraints: [NSLayoutConstraint] = []

    var resultCount: Int = 0 {
        didSet {
            let text = resultCount == 0 ? "No results" : "\(resultCount) found"
            resultLabel.stringValue = text
            resultLabel.textColor = resultCount == 0 ? .systemRed : .secondaryLabelColor
            prevButton.isEnabled = resultCount > 0
            nextButton.isEnabled = resultCount > 0
        }
    }

    // swiftlint:disable:next function_body_length
    override func loadView() {
        // Pill-shaped container
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 410, height: 48))
        root.material = .hudWindow
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
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
        searchField.translatesAutoresizingMaskIntoConstraints = false

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
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            resultLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            resultLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            resultLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 52),
            resultLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),

            prevButton.leadingAnchor.constraint(equalTo: resultLabel.trailingAnchor, constant: 4),
            prevButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 28),
            prevButton.heightAnchor.constraint(equalToConstant: 28),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 28),
            nextButton.heightAnchor.constraint(equalToConstant: 28),

            closeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("excerpt"))
        column.title = "Results"
        resultsTable = NSTableView()
        resultsTable.headerView = nil
        resultsTable.rowHeight = 42
        resultsTable.addTableColumn(column)
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.backgroundColor = .clear
        resultsTable.selectionHighlightStyle = .regular
        resultsScroll = NSScrollView()
        resultsScroll.documentView = resultsTable
        resultsScroll.hasVerticalScroller = true
        resultsScroll.drawsBackground = false
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.isHidden = true
        root.addSubview(resultsScroll)
        resultsPanelConstraints = [
            resultsScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            resultsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            resultsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            resultsScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.deactivate(resultsPanelConstraints)
        rootHeightConstraint = root.heightAnchor.constraint(equalToConstant: 48)
        rootHeightConstraint.isActive = true

        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusSearchField(selectAll: false)
    }

    func focusSearchField(selectAll: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            window.makeFirstResponder(self.searchField)
            if selectAll, let editor = window.firstResponder as? NSTextView {
                editor.selectAll(nil)
            }
        }
    }

    func beginSearch(with text: String?) {
        _ = view
        searchField.stringValue = text ?? ""
        setExpanded(!(text ?? "").isEmpty)
        if let text, !text.isEmpty { delegate?.searchBar(self, didSearch: text) }
        focusSearchField(selectAll: text?.isEmpty == false)
    }

    func showResults(_ results: [BookSearchResult], chapterTitles: [Int: String]) {
        self.results = results
        selectedResultIndex = -1
        self.chapterTitles = chapterTitles
        resultCount = results.count
        resultLabel.stringValue =
            results.isEmpty ? "No results" : (results.count >= 250 ? "250+ found" : "\(results.count) found")
        resultsTable.reloadData()
        setExpanded(!searchField.stringValue.isEmpty)
    }

    var searchFieldValue: String { searchField.stringValue }

    func selectResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedResultIndex = index
        resultsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        resultsTable.scrollRowToVisible(index)
        delegate?.searchBar(self, didSelect: results[index])
    }

    func stepResult(by delta: Int) {
        guard !results.isEmpty else { return }
        let base = selectedResultIndex < 0 ? (delta > 0 ? -1 : 0) : selectedResultIndex
        selectResult(at: (base + delta + results.count) % results.count)
    }

    private var chapterTitles: [Int: String] = [:]

    // MARK: - Public

    func clear() {
        searchField.stringValue = ""
        results = []
        chapterTitles = [:]
        selectedResultIndex = -1
        resultsTable?.reloadData()
        resultCount = 0
        resultLabel.stringValue = ""
        setExpanded(false)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        resultsScroll.isHidden = !value
        rootHeightConstraint.constant = value ? 340 : 48
        if value {
            NSLayoutConstraint.activate(resultsPanelConstraints)
        } else {
            NSLayoutConstraint.deactivate(resultsPanelConstraints)
        }
        onExpandedChange?(value)
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
        setExpanded(!field.stringValue.isEmpty)
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

extension SearchBarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("SearchExcerptCell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let view = NSTableCellView()
                view.identifier = id
                let label = NSTextField(wrappingLabelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.maximumNumberOfLines = 2
                view.addSubview(label)
                view.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                    label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                    label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                return view
            }()
        let result = results[row]
        let title = chapterTitles[result.spineIndex] ?? "Chapter \(result.spineIndex + 1)"
        cell.textField?.stringValue = "\(title)  ·  \(result.excerpt)"
        cell.textField?.font = NSFont.systemFont(ofSize: 11)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = resultsTable.selectedRow
        guard results.indices.contains(row) else { return }
        guard selectedResultIndex != row else { return }
        selectedResultIndex = row
        delegate?.searchBar(self, didSelect: results[row])
    }
}
