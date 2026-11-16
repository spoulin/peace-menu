import AppKit
import SwiftUI

/// "Arranging the menu bar…" over every screen while a full layout runs. It covers each screen
/// below its menu bar, so the menu bar stays in sight (and the drags that move its icons can't
/// land on the overlay), and lets every click through.
enum Overlay {
    private static var windows: [NSWindow] = []

    static func show() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let bar = screen.frame.maxY - screen.visibleFrame.maxY // the menu bar's height
            var frame = screen.frame
            frame.size.height -= bar
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: OverlayView())
            w.alphaValue = 0
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    static func hide() {
        let closing = windows
        windows = []
        guard !closing.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        })
    }
}

private struct OverlayView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Arranging the menu bar…").font(.title3.weight(.medium))
                Text("Just a moment: PeaceMenu is moving icons.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
