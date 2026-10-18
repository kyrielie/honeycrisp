import AppKit

final class TOCPopupViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((TOCEntry) -> Void)?
    private let entries: [TOCEntry]
    private let currentChapterURL: URL
    private var outlineView: NSOutlineView!

    init(entries: [TOCEntry], currentChapterURL: URL) {
        self.entries = entries
        self.currentChapterURL = Self.chapterURL(for: currentChapterURL)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
        root.material = .hudWindow
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        root.layer?.borderWidth = 0.5

        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 32
        outlineView.indentationPerLevel = 18
        outlineView.style = .sourceList
        outlineView.target = self
        outlineView.action = #selector(selectRow(_:))
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
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        outlineView.reloadData()
        for entry in entries where !entry.children.isEmpty { outlineView.expandItem(entry) }
        guard let row = (0..<outlineView.numberOfRows).first(where: { row in
            guard let entry = outlineView.item(atRow: row) as? TOCEntry else { return false }
            return Self.chapterURL(for: entry.absoluteURL) == currentChapterURL
        }) else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let entry = item as? TOCEntry else { return entries.count }
        return entry.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let entry = item as? TOCEntry else { return entries[index] }
        return entry.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? TOCEntry)?.children ?? []).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? TOCEntry else { return nil }
        let label = NSTextField(labelWithString: entry.title)
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 13, weight: entry.depth == 0 ? .medium : .regular)
        label.toolTip = entry.title
        if Self.chapterURL(for: entry.absoluteURL) == currentChapterURL {
            label.textColor = .controlAccentColor
        }
        return label
    }

    @objc private func selectRow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let entry = outlineView.item(atRow: row) as? TOCEntry else { return }
        onSelect?(entry)
    }

    private static func chapterURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.standardizedFileURL
        }
        components.fragment = nil
        return (components.url ?? url).standardizedFileURL
    }
}
