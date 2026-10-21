import Foundation
import WebKit

/// Receives the shell script's `hostPosition` posts (client world) and forwards them to the surface.
@MainActor
final class ChapterHostPositionHandler: NSObject, WKScriptMessageHandler {
    private weak var surface: ChapterHostSurface?

    init(surface: ChapterHostSurface) { self.surface = surface }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        surface?.receivePosition(message.body)
    }
}

/// Receives the pager's `pageAction` and `positionUpdate` posts (client world, paged chapters).
@MainActor
final class ChapterHostPagerHandler: NSObject, WKScriptMessageHandler {
    enum Kind { case pageAction, positionUpdate }

    private weak var surface: ChapterHostSurface?
    private let kind: Kind

    init(surface: ChapterHostSurface, kind: Kind) {
        self.surface = surface
        self.kind = kind
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch kind {
        case .pageAction: surface?.receivePageAction(message.body)
        case .positionUpdate: surface?.receivePagerPosition(message.body)
        }
    }
}
