// TOCPopupViewController.swift
// Popup Table of Contents with search filtering and keyboard navigation.

import AppKit

final class TOCPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A TOC panel is a child of the reader window; menu routing wants the reader window.
    static func hostWindow(for window: NSWindow?) -> NSWindow? {
        (window as? TOCPanel)?.parent ?? window
    }
}

final class TOCOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, Keypad Enter
            if let onActivate {
                onActivate()
                return
            }
        case 53:      // Escape
            if let onCancel {
                onCancel()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

private final class TOCRowCell: NSTableCellView {
    var item: TOCItem?
    var isCurrent: Bool = false
    let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: TOCItem, isCurrent: Bool) {
        self.item = item
        self.isCurrent = isCurrent
        titleLabel.stringValue = item.title
        toolTip = item.title

        let fontSize: CGFloat = 13
        let fontWeight: NSFont.Weight = isCurrent ? .semibold : (item.depth == 0 ? .medium : .regular)
        titleLabel.font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        guard let item else { return }
        if backgroundStyle == .emphasized {
            titleLabel.textColor = .alternateSelectedControlTextColor
        } else if isCurrent {
            titleLabel.textColor = .controlAccentColor
        } else if item.isSelectable {
            titleLabel.textColor = .labelColor
        } else {
            titleLabel.textColor = .tertiaryLabelColor
        }
    }
}

final class TOCPopupViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((TOCEntry) -> Void)?
    var onDismiss: (() -> Void)?

    let model: TOCModel
    private(set) var searchField: NSSearchField!
    private(set) var outlineView: TOCOutlineView!
    private(set) var emptyLabel: NSTextField!
    private var isApplyingState = false

    init(model: TOCModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 440, height: 500))
        root.material = .hudWindow
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        root.layer?.borderWidth = 0.5

        setupSearchField(in: root)
        let scroll = setupOutlineView(in: root)
        setupEmptyLabel(in: root, scroll: scroll)
        self.view = root
    }

    private func setupSearchField(in root: NSView) {
        searchField = NSSearchField()
        searchField.placeholderString = "Filter contents"
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setupOutlineView(in root: NSView) -> NSScrollView {
        outlineView = TOCOutlineView()
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 16
        outlineView.style = .sourceList
        outlineView.target = self
        outlineView.action = #selector(outlineClicked(_:))
        outlineView.onActivate = { [weak self] in self?.activateSelectedItem() }
        outlineView.onCancel = { [weak self] in self?.handleCancel() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("toc-entry"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        return scroll
    }

    private func setupEmptyLabel(in root: NSView, scroll: NSScrollView) {
        emptyLabel = NSTextField(labelWithString: "No matches")
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        prepareForDisplay()
    }

    func prepareForDisplay() {
        model.setFilter("")
        searchField.stringValue = ""
        model.revealCurrent()
        outlineView.reloadData()

        applyExpansionState()

        if let current = model.current {
            let row = outlineView.row(forItem: current)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        }
        updateEmptyState()
        view.window?.makeFirstResponder(searchField)
    }

    private func applyExpansionState() {
        isApplyingState = true
        defer { isApplyingState = false }

        func syncExpansion(_ item: TOCItem) {
            let hasVisibleChildren = !model.visibleChildren(of: item).isEmpty
            guard hasVisibleChildren else { return }

            if model.isExpanded(item) {
                outlineView.expandItem(item)
                for child in model.visibleChildren(of: item) {
                    syncExpansion(child)
                }
            } else {
                outlineView.collapseItem(item)
            }
        }

        for root in model.visibleChildren(of: nil) {
            syncExpansion(root)
        }
    }

    private func updateEmptyState() {
        let hasItems = !model.visibleChildren(of: nil).isEmpty
        emptyLabel.isHidden = hasItems
        if !hasItems {
            emptyLabel.stringValue = model.roots.isEmpty ? "No table of contents" : "No matches"
        }
    }

    // MARK: - NSOutlineViewDataSource & Delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        model.visibleChildren(of: item as? TOCItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        model.visibleChildren(of: item as? TOCItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let tocItem = item as? TOCItem else { return false }
        return !model.visibleChildren(of: tocItem).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? TOCItem)?.isSelectable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tocItem = item as? TOCItem else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("TOCRowCell")
        let cell = (outlineView.makeView(withIdentifier: cellID, owner: self) as? TOCRowCell) ?? TOCRowCell()
        cell.identifier = cellID
        let isCurrent = (model.current === tocItem)
        cell.configure(with: tocItem, isCurrent: isCurrent)
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplyingState, let item = notification.userInfo?["NSObject"] as? TOCItem else { return }
        model.setExpanded(true, for: item)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingState, let item = notification.userInfo?["NSObject"] as? TOCItem else { return }
        model.setExpanded(false, for: item)
    }

    // MARK: - Actions & Keyboard

    @objc private func outlineClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? TOCItem, item.isSelectable else { return }
        onSelect?(item.entry)
    }

    private func activateSelectedItem() {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? TOCItem, item.isSelectable else { return }
        onSelect?(item.entry)
    }

    private func handleCancel() {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        } else {
            onDismiss?()
        }
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        model.setFilter(searchField.stringValue)
        outlineView.reloadData()
        applyExpansionState()
        updateEmptyState()

        let target = model.firstSelectableMatch ?? (searchField.stringValue.isEmpty ? model.current : nil)
        if let target {
            let row = outlineView.row(forItem: target)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        } else {
            outlineView.deselectAll(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            selectNextRow(forward: true)
            return true
        } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
            selectNextRow(forward: false)
            return true
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if outlineView.selectedRow >= 0,
               let item = outlineView.item(atRow: outlineView.selectedRow) as? TOCItem,
               item.isSelectable {
                onSelect?(item.entry)
            } else if let match = model.firstSelectableMatch {
                onSelect?(match.entry)
            }
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            handleCancel()
            return true
        }
        return false
    }

    private func selectNextRow(forward: Bool) {
        let count = outlineView.numberOfRows
        guard count > 0 else { return }
        let current = outlineView.selectedRow
        let delta = forward ? 1 : -1
        var candidate = current + delta

        while candidate >= 0 && candidate < count {
            if let item = outlineView.item(atRow: candidate) as? TOCItem, item.isSelectable {
                outlineView.selectRowIndexes(IndexSet(integer: candidate), byExtendingSelection: false)
                outlineView.scrollRowToVisible(candidate)
                return
            }
            candidate += delta
        }
    }
}
