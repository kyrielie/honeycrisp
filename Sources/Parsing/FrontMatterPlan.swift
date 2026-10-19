import Foundation

enum SpineRole: Equatable {
    case primaryPreface, cut, chapter, backMatter
}

struct FrontMatterPlan: Equatable {
    let roles: [SpineRole]

    func isHidden(_ index: Int) -> Bool {
        roles.indices.contains(index) && roles[index] == .cut
    }

    func resolveVisible(from index: Int, forward: Bool) -> Int {
        guard !roles.isEmpty else { return 0 }
        var candidate = min(max(0, index), roles.count - 1)
        while isHidden(candidate) {
            let next = candidate + (forward ? 1 : -1)
            if !roles.indices.contains(next) {
                if let primary = roles.firstIndex(of: .primaryPreface) { return primary }
                return min(max(0, index), roles.count - 1)
            }
            candidate = next
        }
        return candidate
    }

    var frontCount: Int {
        roles.prefix { $0 == .primaryPreface || $0 == .cut }.count
    }

    var backCount: Int {
        roles.reversed().prefix { $0 == .backMatter }.count
    }

    func visibleOrdinal(of index: Int) -> (position: Int, total: Int) {
        let visible = roles.indices.filter { !isHidden($0) }
        guard let ordinal = visible.firstIndex(of: index) else { return (1, max(1, visible.count)) }
        return (ordinal + 1, max(1, visible.count))
    }

    static func detect(in package: EPUBPackage, identity: BookIdentity? = nil) -> FrontMatterPlan? {
        let identity = identity ?? BookIdentity.detect(package)
        guard identity.generator == .ao3Native || identity.generator == .fichub ||
              identity.generator == .ficlab || identity.generator == .webToEpub else { return nil }
        let docs = package.spineURLs.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
        guard !docs.isEmpty else { return nil }
        var roles = Array(repeating: SpineRole.chapter, count: docs.count)
        switch identity.generator {
        case .ao3Native:
            var leading = 0
            while leading < docs.count && docs[leading].range(of: #"(?is)<[^>]+id=[\"']preface[\"'][^>]*>"#, options: .regularExpression) != nil {
                roles[leading] = leading == 0 ? .primaryPreface : .cut
                leading += 1
            }
            guard leading > 0 else { return nil }
            for index in leading..<docs.count {
                let body = docs[index]
                let hasChapters = body.range(of: #"(?is)<[^>]+id=[\"']chapters[\"'][^>]*>\s*.+?</[^>]+>"#, options: .regularExpression) != nil
                if hasChapters && !body.contains("id=\"preface\"") { roles[index] = .chapter }
                else if body.range(of: #"(?is)<[^>]+id=[\"']afterword[\"'][^>]*>\s*<(?:h[1-6]|p|div)"#, options: .regularExpression) != nil { roles[index] = .backMatter }
            }
        case .fichub:
            guard let index = docs.firstIndex(where: { $0.localizedCaseInsensitiveContains("Exported with the assistance of FicHub") }) else { return nil }
            guard index == 0 else { return nil }
            roles[index] = .primaryPreface
            if index + 1 < docs.count && docs[index + 1].lowercased().contains("<nav") { roles[index + 1] = .cut }
        case .ficlab:
            var index = 0
            while index < docs.count {
                let lower = docs[index].lowercased()
                let isFront = ["fl-cover", "fl-title", "fl-copyright", "fl-toc", "fl-summary"].contains { lower.contains($0) }
                guard isFront else { break }
                roles[index] = index == 0 ? .primaryPreface : .cut
                index += 1
            }
            guard index > 0 else { return nil }
        case .webToEpub:
            guard let index = docs.firstIndex(where: { $0.lowercased().contains("work meta group") }) else { return nil }
            guard index == 0 else { return nil }
            roles[index] = .primaryPreface
        default: return nil
        }
        return FrontMatterPlan(roles: roles)
    }
}

