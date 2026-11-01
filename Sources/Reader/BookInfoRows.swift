// BookInfoRows.swift
// Pure row model for the Book Info sheet (FRAMEWORK L5 Shell). Foundation-only so it is testable
// without AppKit: `BookInfoViewController` renders whatever rows this produces.

import Foundation

struct BookInfoRow: Equatable {
    let label: String
    let value: String
}

enum BookInfoRows {

    /// Shown where a base field is missing.
    static let placeholder = "\u{2014}"

    /// The always-present rows. With AO3 metadata the spine-item count is dropped (the AO3 section
    /// reports the work's own chapter count) and a missing language falls back to the AO3 one.
    /// `description` is the cleaned OPF description; it gets a last row unless an AO3 summary is shown.
    static func baseRows(
        package: EPUBPackage,
        formatName: String,
        ao3: AO3MetadataRecord?,
        description: String? = nil
    ) -> [BookInfoRow] {
        var rows = [BookInfoRow(label: "Format", value: formatName)]
        if ao3 == nil {
            rows.append(BookInfoRow(label: "Chapters", value: "\(package.spineURLs.count)"))
        }
        rows.append(BookInfoRow(label: "Publisher", value: package.publisher ?? placeholder))
        rows.append(BookInfoRow(label: "Date", value: package.publicationDate ?? placeholder))
        rows.append(BookInfoRow(label: "Language", value: package.language ?? ao3?.language ?? placeholder))
        rows.append(BookInfoRow(label: "Identifier", value: package.identifier ?? placeholder))
        if let description, !description.isEmpty, ao3?.summary == nil {
            rows.append(BookInfoRow(label: "Description", value: description))
        }
        return rows
    }

    /// The AO3 section: only fields that are present, in display order.
    static func ao3Rows(_ record: AO3MetadataRecord, locale: Locale = .current) -> [BookInfoRow] {
        var rows: [BookInfoRow] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(BookInfoRow(label: label, value: value))
        }
        func addList(_ label: String, _ values: [String]) {
            add(label, values.isEmpty ? nil : values.joined(separator: ", "))
        }

        add("Rating", record.rating)
        addList("Warnings", record.warnings)
        addList("Categories", record.categories)
        addList("Fandoms", record.fandoms)
        addList("Relationships", record.relationships)
        addList("Characters", record.characters)
        addList("Tags", record.additionalTags)
        add("Series", record.series.isEmpty ? nil : record.series.map { "Part \($0.index) of \($0.name)" }.joined(separator: "; "))
        addList("Collections", record.collections)
        add("Summary", record.summary)
        add("Words", record.wordCount.map { grouped($0, locale: locale) })
        add("Chapters", chaptersText(record))
        if record.isComplete || record.chapterCurrent != nil {
            add("Status", record.isComplete ? "Complete" : "In progress")
        }
        add("Published", record.publishedDate)
        add("Updated", record.updatedDate)
        add("Kudos", record.kudosCount.map { grouped($0, locale: locale) })
        add("Link", record.storyURL)
        return rows
    }

    /// `3/10`, or `3/?` while the total is unknown.
    private static func chaptersText(_ record: AO3MetadataRecord) -> String? {
        guard let current = record.chapterCurrent else { return nil }
        return "\(current)/\(record.chapterTotal.map(String.init) ?? "?")"
    }

    private static func grouped(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
