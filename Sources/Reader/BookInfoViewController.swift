// BookInfoViewController.swift
// Native modal sheet presenting book metadata and reading statistics (FRAMEWORK L5 Shell)

import AppKit

final class BookInfoViewController: NSViewController {

    private let package: EPUBPackage
    private let sourceURL: URL?
    private let ao3: AO3MetadataRecord?

    private static let baseHeight: CGFloat = 420
    private static let ao3Height: CGFloat = 560
    private static let labelColumnWidth: CGFloat = 96
    private static let rowSpacing: CGFloat = 12
    /// Wrap width for value text: sheet width, minus 20 pt side padding, a legacy scroller (16 pt),
    /// the label column and the gap. Slightly narrow with overlay scrollers, which only costs a spare line.
    private static let valueWrapWidth: CGFloat = 480 - 40 - 16 - labelColumnWidth - rowSpacing

    init(package: EPUBPackage, sourceURL: URL?, ao3: AO3MetadataRecord? = nil) {
        self.package = package
        self.sourceURL = sourceURL
        self.ao3 = ao3
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let ao3Rows = ao3.map { BookInfoRows.ao3Rows($0) } ?? []
        let height = ao3Rows.isEmpty ? Self.baseHeight : Self.ao3Height
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: height))
        root.wantsLayer = true

        // Everything above the Done button is one scrolling panel, so long AO3 tag lists scroll
        // together with the rest of the metadata instead of in a box of their own.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let (stack, fullWidthViews) = buildContentStack(ao3Rows: ao3Rows)
        content.addSubview(stack)

        let footerSeparator = createSeparator()
        let buttonBox = createButtonBox()
        root.addSubview(footerSeparator)
        root.addSubview(buttonBox)

        var constraints: [NSLayoutConstraint] = [
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -8),

            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footerSeparator.bottomAnchor.constraint(equalTo: buttonBox.topAnchor, constant: -14),

            buttonBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttonBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttonBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ]
        constraints += fullWidthViews.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
        NSLayoutConstraint.activate(constraints)

        self.view = root
    }

    /// Header, base fields, optional AO3 section and description, stacked top to bottom.
    /// Also returns the views that must span the stack's full width.
    private func buildContentStack(ao3Rows: [BookInfoRow]) -> (stack: NSStackView, fullWidth: [NSView]) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headerBox = createHeaderView()
        let separator = createSeparator()
        let baseRows = createRowsView(BookInfoRows.baseRows(package: package, formatName: formatDescription(), ao3: ao3))
        var fullWidthViews: [NSView] = [headerBox, separator, baseRows]
        stack.addArrangedSubview(headerBox)
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(baseRows)

        if let ao3Section = createAO3Section(rows: ao3Rows) {
            stack.addArrangedSubview(ao3Section)
            fullWidthViews.append(ao3Section)
        }
        if let descView = createDescriptionView() {
            stack.addArrangedSubview(descView)
        }
        return (stack, fullWidthViews)
    }

    private func createHeaderView() -> NSView {
        let headerBox = NSView()
        headerBox.translatesAutoresizingMaskIntoConstraints = false

        let coverView = NSImageView()
        coverView.imageScaling = .scaleProportionallyUpOrDown
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 6
        coverView.layer?.masksToBounds = true
        coverView.layer?.borderColor = NSColor.separatorColor.cgColor
        coverView.layer?.borderWidth = 0.5
        coverView.translatesAutoresizingMaskIntoConstraints = false

        if let coverURL = package.coverURL, let img = NSImage(contentsOf: coverURL) {
            coverView.image = img
        } else {
            let symbol = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Book cover")
            coverView.image = symbol
            coverView.contentTintColor = .secondaryLabelColor
        }
        headerBox.addSubview(coverView)

        let titleLabel = NSTextField(labelWithString: package.title.isEmpty ? "Untitled Document" : package.title)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.isSelectable = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBox.addSubview(titleLabel)

        let authorText = package.author.isEmpty ? "Unknown Author" : package.author
        let authorLabel = NSTextField(labelWithString: "By \(authorText)")
        authorLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.isSelectable = true
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBox.addSubview(authorLabel)

        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
            coverView.topAnchor.constraint(equalTo: headerBox.topAnchor),
            coverView.bottomAnchor.constraint(lessThanOrEqualTo: headerBox.bottomAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 72),
            coverView.heightAnchor.constraint(equalToConstant: 96),

            titleLabel.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 4),

            authorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
            authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
        return headerBox
    }

    /// One `Label: value` line per row, label right-aligned in a fixed column and the value wrapping.
    private func createRowsView(_ rows: [BookInfoRow]) -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        for row in rows {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            line.distribution = .fill
            line.spacing = Self.rowSpacing

            let label = createRowLabel("\(row.label):")
            line.addArrangedSubview(label)
            line.addArrangedSubview(createValueLabel(row.value))
            label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true

            column.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    /// "Archive of Our Own" heading over the same label and value rows as the base fields.
    private func createAO3Section(rows: [BookInfoRow]) -> NSView? {
        guard !rows.isEmpty else { return nil }
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let title = NSTextField(labelWithString: "Archive of Our Own")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        container.addArrangedSubview(title)

        let rowsView = createRowsView(rows)
        container.addArrangedSubview(rowsView)
        rowsView.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private func createDescriptionView() -> NSView? {
        guard let desc = package.bookDescription, !desc.isEmpty else { return nil }
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let descTitle = NSTextField(labelWithString: "Description:")
        descTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        descTitle.textColor = .secondaryLabelColor
        container.addArrangedSubview(descTitle)

        let descScroll = NSScrollView()
        descScroll.hasVerticalScroller = true
        descScroll.drawsBackground = false
        descScroll.translatesAutoresizingMaskIntoConstraints = false
        descScroll.heightAnchor.constraint(equalToConstant: 70).isActive = true

        let descText = NSTextView()
        descText.isEditable = false
        descText.isSelectable = true
        descText.drawsBackground = false
        descText.font = NSFont.systemFont(ofSize: 11)
        descText.string = Self.cleanDescription(desc)
        descScroll.documentView = descText
        container.addArrangedSubview(descScroll)
        return container
    }

    static func cleanDescription(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
            ("&nbsp;", " "),
            ("&copy;", "©"),
            ("&trade;", "™"),
            ("&reg;", "®"),
        ]
        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        if text.contains("&#") {
            let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);", options: [.caseInsensitive])
            let nsString = text as NSString
            let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []
            for match in matches.reversed() {
                let entityString = nsString.substring(with: match.range(at: 1))
                var codePoint: UInt32?
                if entityString.lowercased().hasPrefix("x") {
                    let hex = String(entityString.dropFirst())
                    codePoint = UInt32(hex, radix: 16)
                } else {
                    codePoint = UInt32(entityString, radix: 10)
                }
                if let cp = codePoint, let scalar = UnicodeScalar(cp) {
                    let char = String(Character(scalar))
                    text = (text as NSString).replacingCharacters(in: match.range, with: char)
                }
            }
        }
        text = text.replacingOccurrences(of: "[ \t\r\n]+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createButtonBox() -> NSView {
        let buttonBox = NSView()
        buttonBox.translatesAutoresizingMaskIntoConstraints = false
        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        buttonBox.addSubview(doneButton)

        NSLayoutConstraint.activate([
            doneButton.trailingAnchor.constraint(equalTo: buttonBox.trailingAnchor),
            doneButton.topAnchor.constraint(equalTo: buttonBox.topAnchor),
            doneButton.bottomAnchor.constraint(equalTo: buttonBox.bottomAnchor),
        ])
        return buttonBox
    }

    private func createRowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func createValueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = Self.valueWrapWidth
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func createSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func formatDescription() -> String {
        guard let url = sourceURL else { return "EPUB Document" }
        return BookFormat.detect(url: url)?.displayName ?? "EPUB Document"
    }

    @objc private func dismissSheet() {
        dismiss(nil)
    }
}

/// Document view for the Book Info scroll view: flipped so content starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
