import Foundation

struct Person: Equatable {
    var name: String
    var url: URL?
}

struct WorkMeta: Equatable {
    struct Row: Equatable {
        var label: String
        var values: [Value]
        var isWide: Bool
        var kind: String?

        struct Value: Equatable {
            var text: String
            var href: URL?
        }
    }

    var title: String
    var authors: [Person]
    var siteLabel: String?
    var sourceURL: URL?
    var summaryHTML: String?
    var notesHTML: String?
    var rows: [Row]
    var stats: [(label: String, value: String)]

    static func == (lhs: WorkMeta, rhs: WorkMeta) -> Bool {
        lhs.title == rhs.title && lhs.authors == rhs.authors && lhs.siteLabel == rhs.siteLabel &&
        lhs.sourceURL == rhs.sourceURL && lhs.summaryHTML == rhs.summaryHTML && lhs.notesHTML == rhs.notesHTML &&
        lhs.rows == rhs.rows && lhs.stats.elementsEqual(rhs.stats, by: { $0.label == $1.label && $0.value == $1.value })
    }
}

