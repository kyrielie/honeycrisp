// BookInfoViewController.swift
// Native modal sheet presenting book metadata and reading statistics (FRAMEWORK L5 Shell)

import AppKit

final class BookInfoViewController: NSViewController {

    private let package: EPUBPackage
    private let sourceURL: URL?

    init(package: EPUBPackage, sourceURL: URL?) {
        self.package = package
        self.sourceURL = sourceURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))
        root.wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let headerBox = createHeaderView()
        stack.addArrangedSubview(headerBox)

        let separator1 = createSeparator()
        stack.addArrangedSubview(separator1)

        let grid = createMetadataGrid()
        stack.addArrangedSubview(grid)

        if let descView = createDescriptionView() {
            stack.addArrangedSubview(descView)
        }

        let separator2 = createSeparator()
        stack.addArrangedSubview(separator2)

        let buttonBox = createButtonBox()
        stack.addArrangedSubview(buttonBox)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            headerBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator1.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator2.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        self.view = root
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

    private func createMetadataGrid() -> NSGridView {
        let grid = NSGridView(views: [
            [createRowLabel("Format:"), createValueLabel(formatDescription())],
            [createRowLabel("Chapters:"), createValueLabel("\(package.spineURLs.count)")],
            [createRowLabel("Publisher:"), createValueLabel(package.publisher ?? "—")],
            [createRowLabel("Date:"), createValueLabel(package.publicationDate ?? "—")],
            [createRowLabel("Language:"), createValueLabel(package.language ?? "—")],
            [createRowLabel("Identifier:"), createValueLabel(package.identifier ?? "—")],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        return grid
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
        descText.string = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        descScroll.documentView = descText
        container.addArrangedSubview(descScroll)
        return container
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
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingTail
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
