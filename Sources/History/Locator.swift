import Foundation

/// Position shared by reading surfaces, persistence, and the app shell.
enum Locator: Codable, Equatable {
    case flow(resource: Int, offset: Int, layout: Int, fraction: Double)
    case page(index: Int)

    enum FlowRestoreTarget: Equatable {
        case offset(resource: Int, offset: Int)
        case fraction(resource: Int, fraction: Double)
    }

    /// Use exact offsets only when the saved position uses this build's text layout.
    var flowRestoreTarget: FlowRestoreTarget? {
        guard case let .flow(resource, offset, layout, fraction) = self else { return nil }
        if layout == EPUBAnchor.currentLayout {
            return .offset(resource: max(0, resource), offset: max(0, offset))
        }
        return .fraction(resource: max(0, resource), fraction: Self.clamp(fraction))
    }

    static func clamp(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }
}

struct ResourceProgressMeasure: Equatable {
    /// UTF-16 text length, when the reader has measured it.
    var textLength: Int?
    /// Resource byte size, used until its text length is known.
    var byteSize: Int
}

enum ReadingProgress {
    /// Derive whole-book progress from a flowing locator and per-resource measures.
    static func fraction(for locator: Locator, resources: [ResourceProgressMeasure]) -> Double? {
        guard case let .flow(resource, offset, _, fallbackFraction) = locator,
            resources.indices.contains(resource)
        else { return nil }

        let weights = resources.map { measure in
            max(0, measure.textLength ?? measure.byteSize)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return Double(resource) / Double(max(resources.count, 1)) }

        let currentWeight = weights[resource]
        let withinResource: Double
        if let textLength = resources[resource].textLength, textLength > 0 {
            withinResource = Locator.clamp(Double(max(0, offset)) / Double(textLength))
        } else {
            withinResource = Locator.clamp(fallbackFraction)
        }
        let preceding = weights[..<resource].reduce(0, +)
        return Locator.clamp((Double(preceding) + Double(currentWeight) * withinResource) / Double(total))
    }
}
