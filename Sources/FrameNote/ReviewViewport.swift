import AppKit
import SwiftUI
import FrameNoteCore

/// Native scrolling keeps a zoomed video movable without intercepting annotation drags.
struct ReviewViewport<Content: View>: NSViewRepresentable {
    let documentSize: CGSize
    let imageSize: CGSize
    let center: UnitPoint2D
    let zoom: CGFloat
    var onZoom: (CGFloat, UnitPoint2D) -> Void = { _, _ in }
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CenteredReviewScrollView {
        let view = CenteredReviewScrollView()
        view.hasHorizontalScroller = true; view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.drawsBackground = false
        view.horizontalScrollElasticity = .none; view.verticalScrollElasticity = .none
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        view.documentView = host
        view.onZoom = onZoom
        context.coordinator.host = host
        return view
    }

    func updateNSView(_ view: CenteredReviewScrollView, context: Context) {
        guard let host = context.coordinator.host else { return }
        host.rootView = content()
        host.frame = CGRect(origin: .zero, size: documentSize)
        view.onZoom = onZoom
        view.imageSize = imageSize
        view.documentSize = documentSize
        view.currentZoom = zoom
        let changed = context.coordinator.zoom != zoom || context.coordinator.center != center
            || context.coordinator.documentSize != documentSize
        context.coordinator.zoom = zoom
        context.coordinator.center = center
        context.coordinator.documentSize = documentSize
        guard changed else { return }
        let point = CGPoint(x: (documentSize.width - imageSize.width) / 2 + center.x * imageSize.width,
                            y: (documentSize.height - imageSize.height) / 2 + center.y * imageSize.height)
        if let anchor = view.pendingZoomAnchor {
            view.pendingOrigin = CGPoint(
                x: (documentSize.width - imageSize.width) / 2 + anchor.point.x * imageSize.width - anchor.viewportOffset.x,
                y: (documentSize.height - imageSize.height) / 2 + anchor.point.y * imageSize.height - anchor.viewportOffset.y)
            view.pendingZoomAnchor = nil
        } else { view.pendingCenter = point }
        view.needsLayout = true

    }

    final class Coordinator {
        var host: NSHostingView<Content>?
        var zoom: CGFloat = 0
        var center = UnitPoint2D(x: 0.5, y: 0.5)
        var documentSize = CGSize.zero
    }
}

struct ImmediateToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

@MainActor final class CenteredReviewScrollView: NSScrollView {
    var pendingCenter: CGPoint?
    var pendingOrigin: CGPoint?
    var pendingZoomAnchor: (point: UnitPoint2D, viewportOffset: CGPoint)?
    var imageSize = CGSize.zero
    var documentSize = CGSize.zero
    var currentZoom: CGFloat = 1
    var onZoom: (CGFloat, UnitPoint2D) -> Void = { _, _ in }

    override func magnify(with event: NSEvent) {
        requestZoom(by: max(0.1, 1 + event.magnification), event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            requestZoom(by: exp(-event.scrollingDeltaY * 0.012), event: event)
        } else { super.scrollWheel(with: event) }
    }

    private func requestZoom(by factor: CGFloat, event: NSEvent) {
        guard currentZoom * factor > 1 || factor > 1, currentZoom * factor < 8 || factor < 1,
              let documentView else { return }
        let location = documentView.convert(event.locationInWindow, from: nil)
        let origin = CGPoint(x: (documentSize.width - imageSize.width) / 2,
                             y: (documentSize.height - imageSize.height) / 2)
        let point = UnitPoint2D(x: (location.x - origin.x) / max(imageSize.width, 1),
                                y: (location.y - origin.y) / max(imageSize.height, 1))
        pendingZoomAnchor = (point, CGPoint(x: location.x - contentView.bounds.minX,
                                            y: location.y - contentView.bounds.minY))
        onZoom(factor, point)
    }

    override func layout() {
        super.layout()
        let explicitOrigin = pendingOrigin
        guard let point = explicitOrigin ?? pendingCenter, let documentView,
              contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        pendingCenter = nil; pendingOrigin = nil
        let viewport = contentView.bounds.size, document = documentView.bounds.size
        contentView.scroll(to: CGPoint(
            x: max(0, min(document.width - viewport.width, explicitOrigin == nil ? point.x - viewport.width / 2 : point.x)),
            y: max(0, min(document.height - viewport.height, explicitOrigin == nil ? point.y - viewport.height / 2 : point.y))))
        reflectScrolledClipView(contentView)
    }
}
