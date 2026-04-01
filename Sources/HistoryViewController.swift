// HistoryViewController.swift
// Popover showing recently opened EPUBs with date, progress, open/remove actions

import AppKit

final class HistoryViewController: NSViewController {

    private let onOpen: (URL) -> Void
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var entries: [HistoryEntry] = []

    init(onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 480))

        // Header
        let headerLabel = NSTextField(labelWithString: "Recent Books")
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearHistory(_:)))
        clearBtn.bezelStyle = .inline
        clearBtn.font = NSFont.systemFont(ofSize: 11)
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clearBtn)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep)

        // Table
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.doubleAction = #selector(openSelectedEntry(_:))
        tableView.target = self

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.isEditable = false
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Empty state
        emptyLabel = NSTextField(labelWithString: "No books opened yet")
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            clearBtn.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            clearBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            sep.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        self.view = container
    }

    func reload() {
        // Accessing `view` triggers loadView() if it hasn't run yet, ensuring
        // tableView and emptyLabel are initialised before we touch them.
        _ = self.view

        entries = HistoryManager.shared.entries
        tableView.reloadData()
        emptyLabel.isHidden = !entries.isEmpty
        scrollView.isHidden = entries.isEmpty
    }

    @objc private func openSelectedEntry(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        openEntry(entries[row])
    }

    private func openEntry(_ entry: HistoryEntry) {
        guard let url = HistoryManager.shared.resolveURL(for: entry) else {
            showMissingFileAlert(entry: entry)
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        onOpen(url)
        if didStart { url.stopAccessingSecurityScopedResource() }
    }

    @objc private func clearHistory(_ sender: Any?) {
        HistoryManager.shared.clearAll()
        reload()
    }

    private func showMissingFileAlert(entry: HistoryEntry) {
        let alert = NSAlert()
        alert.messageText = "File Not Found"
        alert.informativeText = "\u{201C}\(entry.title)\u{201D} could not be located. It may have been moved or deleted."
        alert.addButton(withTitle: "Remove from History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            HistoryManager.shared.remove(id: entry.id)
            reload()
        }
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension HistoryViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]

        let cell = HistoryRowView()
        cell.configure(with: entry)
        cell.onRemove = { [weak self] in
            HistoryManager.shared.remove(id: entry.id)
            self?.reload()
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 64 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        openEntry(entries[row])
    }
}

// MARK: - HistoryRowView

final class HistoryRowView: NSTableCellView {

    var onRemove: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressView = NSProgressIndicator()
    private let removeBtn = NSButton()
    private let bookIcon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        bookIcon.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        bookIcon.contentTintColor = .secondaryLabelColor
        bookIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bookIcon)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        progressView.style = .bar
        progressView.isIndeterminate = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.heightAnchor.constraint(equalToConstant: 3).isActive = true
        addSubview(progressView)

        removeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")
        removeBtn.bezelStyle = .inline
        removeBtn.isBordered = false
        removeBtn.target = self
        removeBtn.action = #selector(removeTapped)
        removeBtn.toolTip = "Remove from history"
        removeBtn.alphaValue = 0
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeBtn)

        NSLayoutConstraint.activate([
            bookIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bookIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            bookIcon.widthAnchor.constraint(equalToConstant: 20),
            bookIcon.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: bookIcon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: removeBtn.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progressView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 6),

            removeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            removeBtn.widthAnchor.constraint(equalToConstant: 20),
            removeBtn.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Show/hide remove button on hover
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    func configure(with entry: HistoryEntry) {
        titleLabel.stringValue = entry.title.isEmpty ? entry.url.deletingPathExtension().lastPathComponent : entry.title

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let dateStr = formatter.localizedString(for: entry.openedAt, relativeTo: Date())

        let pct = entry.readingProgressPercent
        detailLabel.stringValue = pct >= 0 ? "\(dateStr) • \(pct)% read" : dateStr

        progressView.doubleValue = pct >= 0 ? Double(pct) : 0
        progressView.isHidden = pct <= 0
    }

    @objc private func removeTapped() {
        onRemove?()
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            removeBtn.animator().alphaValue = 0.5
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            removeBtn.animator().alphaValue = 0
        }
    }
}
