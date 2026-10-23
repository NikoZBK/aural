import AppKit
import SwiftUI

@MainActor private final class LayoutCacheState: ObservableObject {
    @Published var noticeHeight: CGFloat = 0
    @Published var toolbarHeight: CGFloat = 44
}

private struct ChangingLayoutProbe: View {
    @ObservedObject var state: LayoutCacheState
    let probe: NSView
    let notice: Bool
    var body: some View { ZoomLayoutProbe(view: probe).frame(height: notice ? state.noticeHeight : state.toolbarHeight) }
}

@MainActor func checkWorkspaceLayoutCache() {
    let state = LayoutCacheState()
    let probes = (0..<6).map { _ in NSView() }
    // Only the children observe state: changes must invalidate the parent cache
    // even when the container's own arguments and child identities stay intact.
    let host = NSHostingView(rootView: AuralWorkspaceLayout(availableHeight: 620, minimumInspectorHeight: 80) {
        ChangingLayoutProbe(state: state, probe: probes[0], notice: false)
        ChangingLayoutProbe(state: state, probe: probes[1], notice: true)
        ZoomLayoutProbe(view: probes[2]).frame(minHeight: 200, maxHeight: .infinity)
        ZoomLayoutProbe(view: probes[3])
        ZoomLayoutProbe(view: probes[4]).frame(height: 24)
        ZoomLayoutProbe(view: probes[5]).frame(minHeight: 80, idealHeight: 146, maxHeight: 146)
    })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = host
    func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
    func frame(_ index: Int) -> CGRect { probes[index].convert(probes[index].bounds, to: host) }
    flush()
    for height: CGFloat in [37, 95, 0, 61, 0] {
        state.noticeHeight = height
        flush()
        let top = state.toolbarHeight + 12 + (height > 0 ? height + 12 : 0)
        require(abs(frame(2).minY - top) < 1 && abs(frame(1).height - height) < 1,
                "Cached layout must follow internal notice changes without stale heights or overlaps: \(height), \(frame(2))")
    }
    state.toolbarHeight = 83
    flush()
    require(abs(frame(0).height - 83) < 1 && abs(frame(2).minY - 95) < 1,
            "An internal toolbar size change must invalidate the workspace cache")
    window.setContentSize(NSSize(width: 1100, height: 620))
    flush()
    require(abs(frame(0).width - 1100) < 1 && frame(3).insetBy(dx: -1, dy: -1).contains(frame(4).union(frame(5))),
            "A cached workspace must still resize its surfaces and retain the complete inspector card")
    for scale: CGFloat in [0.8, 1, 1.4] {
        let child = NSView(), peer = NSView()
        let alignmentHost = NSHostingView(rootView: HStack(alignment: .top, spacing: 10) {
            InterfaceZoomLayout(scale: scale) {
                ZoomLayoutProbe(view: child).frame(width: 80, height: 60)
                    .alignmentGuide(.top) { _ in 17 }
            }
            ZoomLayoutProbe(view: peer).frame(width: 40, height: 90)
        })
        alignmentHost.frame = NSRect(x: 0, y: 0, width: 240, height: 140)
        alignmentHost.layoutSubtreeIfNeeded()
        let childFrame = child.convert(child.bounds, to: alignmentHost)
        let peerFrame = peer.convert(peer.bounds, to: alignmentHost)
        require(abs(childFrame.minY - peerFrame.minY) < 1,
                "A complete container must align by its own bounds without inheriting an internal control's guide at \(scale) zoom: \(childFrame), \(peerFrame)")
    }
    print("PASS workspace measurement cache invalidation for internal notices, toolbar sizes, resizing, and inspector frames")
    print("PASS container alignment isolation and consistent outer-frame alignment at fractional zoom")
}
