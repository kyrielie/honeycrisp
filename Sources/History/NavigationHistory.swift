import Foundation

/// An in-book position for navigation history (spine resource index and character offset).
struct NavigationLocation: Equatable, Codable {
    let resource: Int
    let offset: Int

    init(resource: Int, offset: Int = 0) {
        self.resource = max(0, resource)
        self.offset = max(0, offset)
    }
}

/// Pure navigation history stack for back and forward in-book navigation (roadmap M5, Decision R13).
/// Maintains separate back and forward history stacks with bounded capacity and duplicate suppression.
struct NavigationHistoryStack<Item: Equatable> {
    private(set) var backStack: [Item] = []
    private(set) var forwardStack: [Item] = []
    let maxCapacity: Int

    init(maxCapacity: Int = 50) {
        self.maxCapacity = max(1, maxCapacity)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Pushes the prior location onto the back stack and clears the forward stack.
    /// Consecutive duplicate locations are ignored.
    mutating func push(_ item: Item) {
        forwardStack.removeAll()
        if backStack.last == item { return }
        backStack.append(item)
        if backStack.count > maxCapacity {
            backStack.removeFirst(backStack.count - maxCapacity)
        }
    }

    /// Moves back: pushes current location onto forward stack and returns the previous location.
    mutating func goBack(current: Item) -> Item? {
        guard let previous = backStack.popLast() else { return nil }
        if forwardStack.last != current {
            forwardStack.append(current)
            if forwardStack.count > maxCapacity {
                forwardStack.removeFirst(forwardStack.count - maxCapacity)
            }
        }
        return previous
    }

    /// Moves forward: pushes current location onto back stack and returns the next location.
    mutating func goForward(current: Item) -> Item? {
        guard let next = forwardStack.popLast() else { return nil }
        if backStack.last != current {
            backStack.append(current)
            if backStack.count > maxCapacity {
                backStack.removeFirst(backStack.count - maxCapacity)
            }
        }
        return next
    }

    mutating func clear() {
        backStack.removeAll()
        forwardStack.removeAll()
    }
}
