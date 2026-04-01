// TOCSidebarViewController.swift
// Sidebar panel displaying the EPUB Table of Contents

import AppKit

protocol TOCSidebarDelegate: AnyObject {
    func tocSidebar(_ sidebar: TOCSidebarViewController, didSelectEntry entry: TOCEntry)
}

final class TOCSidebarViewController: NSViewController {

    weak var delegate: TOCSidebarDelegate?

    private var entries: [TOCEntry] = []          // flat list (children inlined with indent)
    private var flatEntries: [TOCEntry] = []
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))

        let header = NSTextField(labelWithString: "Contents")
        header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 14
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))

        let col = NSTableColumn(identifier: .init("toc"))
        col.isEditable = false
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        emptyLabel = NSTextField(labelWithString: "No table of contents")
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        self.view = root
    }

    // MARK: - Public

    func load(entries: [TOCEntry]) {
        self.entries = entries
        _ = self.view  // ensure view is loaded
        outlineView.reloadData()
        // Expand top-level items that have children
        for entry in entries where !entry.children.isEmpty {
            outlineView.expandItem(entry)
        }
        emptyLabel.isHidden = !entries.isEmpty
        scrollView.isHidden = entries.isEmpty
    }

    // MARK: - Actions

    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let entry = outlineView.item(atRow: row) as? TOCEntry else { return }
        delegate?.tocSidebar(self, didSelectEntry: entry)
    }
}

// MARK: - NSOutlineViewDataSource

extension TOCSidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return entries.count }
        return (item as? TOCEntry)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return entries[index] }
        return (item as! TOCEntry).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return !((item as? TOCEntry)?.children ?? []).isEmpty
    }
}

// MARK: - NSOutlineViewDelegate

extension TOCSidebarViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? TOCEntry else { return nil }

        let cellID = NSUserInterfaceItemIdentifier("TOCCell")
        var cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell?.addSubview(tf)
            cell?.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
            ])
        }

        cell?.textField?.stringValue = entry.title
        cell?.textField?.font = entry.depth == 0
            ? NSFont.systemFont(ofSize: 12, weight: .medium)
            : NSFont.systemFont(ofSize: 11)
        cell?.textField?.textColor = entry.depth == 0 ? .labelColor : .secondaryLabelColor
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return ((item as? TOCEntry)?.depth ?? 0) == 0 ? 28 : 24
    }
}
