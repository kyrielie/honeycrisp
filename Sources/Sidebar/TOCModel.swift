// TOCModel.swift
// Pure model for Table of Contents hierarchy, selection, expansion, and filtering.

import Foundation

struct TOCLocation: Equatable {
    var spineIndex: Int
    var fragment: String?  // nil or non-empty, percent-decoded
}

final class TOCItem {
    let entry: TOCEntry          // original value, handed back to caller on activation
    let title: String            // entry.title with whitespace and newlines collapsed to single spaces, trimmed
    let fragment: String?        // from entry.absoluteURL; empty becomes nil, percent-decoded
    let spineIndex: Int?         // nil when entry's file is not in spineURLs
    let depth: Int               // entry.depth
    let order: Int               // entry.playOrder
    private(set) weak var parent: TOCItem?
    private(set) var children: [TOCItem]

    var isSelectable: Bool { spineIndex != nil }

    init(entry: TOCEntry, title: String, fragment: String?, spineIndex: Int?, depth: Int, order: Int, children: [TOCItem] = []) {
        self.entry = entry
        self.title = title
        self.fragment = fragment
        self.spineIndex = spineIndex
        self.depth = depth
        self.order = order
        self.children = children
    }

    fileprivate func setParent(_ parent: TOCItem?) {
        self.parent = parent
    }

    fileprivate func setChildren(_ children: [TOCItem]) {
        self.children = children
    }
}

final class TOCModel {
    let roots: [TOCItem]
    let items: [TOCItem]  // pre-order outline

    private(set) var current: TOCItem?
    private var lastLocation: TOCLocation?

    private let itemsBySpine: [Int: [TOCItem]]
    private let sortedSpineIndices: [Int]
    private let titleBySpine: [Int: String]

    private var expandedItems = Set<ObjectIdentifier>()
    private(set) var filter: String = ""
    private var filterTokens: [String] = []

    var isFiltering: Bool { !filter.isEmpty }

    init(entries: [TOCEntry], spineURLs: [URL]) {
        let spinePathToIndex = Self.buildSpineIndex(spineURLs)
        let rootItems = entries.map { Self.buildItemTree($0, spinePathToIndex: spinePathToIndex) }
        self.roots = rootItems

        let allItems = Self.collectPreOrder(roots: rootItems)
        self.items = allItems

        var bySpine: [Int: [TOCItem]] = [:]
        for item in allItems {
            if let idx = item.spineIndex {
                bySpine[idx, default: []].append(item)
            }
        }
        self.itemsBySpine = bySpine
        self.sortedSpineIndices = bySpine.keys.sorted()

        var titles: [Int: String] = [:]
        for (idx, spineItems) in bySpine {
            if let shallowest = spineItems.min(by: { $0.depth < $1.depth }) {
                titles[idx] = shallowest.title
            }
        }
        self.titleBySpine = titles

        for root in rootItems where !root.children.isEmpty {
            expandedItems.insert(ObjectIdentifier(root))
        }
    }

    private static func buildSpineIndex(_ spineURLs: [URL]) -> [String: Int] {
        var lookup: [String: Int] = [:]
        for (idx, url) in spineURLs.enumerated() {
            let path = url.standardizedFileURL.path
            if lookup[path] == nil {
                lookup[path] = idx
            }
        }
        return lookup
    }

    private static func buildItemTree(_ entry: TOCEntry, spinePathToIndex: [String: Int]) -> TOCItem {
        let collapsedTitle = normalizeWhitespace(entry.title)
        let path = entry.absoluteURL.standardizedFileURL.path
        let spineIndex = spinePathToIndex[path]
        let rawFrag = URLComponents(url: entry.absoluteURL, resolvingAgainstBaseURL: false)?.fragment
            ?? entry.absoluteURL.fragment
        let fragment: String? = {
            guard let frag = rawFrag, !frag.isEmpty else { return nil }
            return frag.removingPercentEncoding ?? frag
        }()

        let item = TOCItem(
            entry: entry,
            title: collapsedTitle,
            fragment: fragment,
            spineIndex: spineIndex,
            depth: entry.depth,
            order: entry.playOrder
        )

        let childItems = entry.children.map { buildItemTree($0, spinePathToIndex: spinePathToIndex) }
        for child in childItems {
            child.setParent(item)
        }
        item.setChildren(childItems)
        return item
    }

    private static func collectPreOrder(roots: [TOCItem]) -> [TOCItem] {
        var allItems: [TOCItem] = []
        func walk(_ item: TOCItem) {
            allItems.append(item)
            for child in item.children {
                walk(child)
            }
        }
        for root in roots {
            walk(root)
        }
        return allItems
    }

    // MARK: - Title Lookup

    func title(forSpineIndex index: Int) -> String? {
        titleBySpine[index]
    }

    // MARK: - Selection & Current Location

    @discardableResult
    func setCurrent(_ location: TOCLocation?) -> TOCItem? {
        guard let location else {
            current = nil
            lastLocation = nil
            return nil
        }

        var effectiveFragment = location.fragment
        if effectiveFragment == nil, let prev = lastLocation, prev.spineIndex == location.spineIndex {
            effectiveFragment = prev.fragment
        }

        let effectiveLocation = TOCLocation(spineIndex: location.spineIndex, fragment: effectiveFragment)
        if effectiveLocation == lastLocation, let current {
            return current
        }
        lastLocation = effectiveLocation

        // Resolution rule 4:
        // Candidates with matching spineIndex
        if let candidates = itemsBySpine[effectiveLocation.spineIndex], !candidates.isEmpty {
            if let fragment = effectiveLocation.fragment,
               let match = candidates.first(where: { $0.fragment == fragment }) {
                current = match
                return match
            }
            if let fileLevel = candidates.first(where: { $0.fragment == nil }) {
                current = fileLevel
                return fileLevel
            }
            let first = candidates[0]
            current = first
            return first
        }

        // No candidates for this spine index: take greatest listed spine index below location.spineIndex
        let preceding = sortedSpineIndices.last(where: { $0 < effectiveLocation.spineIndex })
        if let preceding, let fallbackCandidates = itemsBySpine[preceding], !fallbackCandidates.isEmpty {
            if let fileLevel = fallbackCandidates.first(where: { $0.fragment == nil }) {
                current = fileLevel
                return fileLevel
            }
            let first = fallbackCandidates[0]
            current = first
            return first
        }

        current = nil
        return nil
    }

    // MARK: - Expansion

    func isExpanded(_ item: TOCItem) -> Bool {
        if isFiltering {
            return !visibleChildren(of: item).isEmpty
        }
        return expandedItems.contains(ObjectIdentifier(item))
    }

    func setExpanded(_ expanded: Bool, for item: TOCItem) {
        guard !isFiltering else { return }
        if expanded {
            expandedItems.insert(ObjectIdentifier(item))
        } else {
            expandedItems.remove(ObjectIdentifier(item))
        }
    }

    func revealCurrent() {
        guard let current else { return }
        var ancestor = current.parent
        while let node = ancestor {
            expandedItems.insert(ObjectIdentifier(node))
            ancestor = node.parent
        }
    }

    // MARK: - Filtering

    func setFilter(_ query: String) {
        let collapsed = Self.normalizeWhitespace(query)
        filter = collapsed
        if collapsed.isEmpty {
            filterTokens = []
        } else {
            filterTokens = collapsed.split(separator: " ").map(String.init)
        }
    }

    func isMatch(_ item: TOCItem) -> Bool {
        guard isFiltering else { return true }
        for token in filterTokens {
            let range = item.title.range(
                of: token,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            )
            if range == nil {
                return false
            }
        }
        return true
    }

    func hasMatchingDescendant(_ item: TOCItem) -> Bool {
        for child in item.children {
            if isMatch(child) || hasMatchingDescendant(child) {
                return true
            }
        }
        return false
    }

    func visibleChildren(of item: TOCItem?) -> [TOCItem] {
        let candidates = item?.children ?? roots
        guard isFiltering else { return candidates }

        return candidates.filter { child in
            isMatch(child) || hasMatchingDescendant(child)
        }
    }

    var firstSelectableMatch: TOCItem? {
        guard isFiltering else { return roots.first(where: \.isSelectable) }
        return items.first { isMatch($0) && $0.isSelectable }
    }

    // MARK: - Helpers

    static func normalizeWhitespace(_ str: String) -> String {
        str.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
