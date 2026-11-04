import Foundation
import CoreGraphics

// The window includes transparent space for the shadow without moving the visible panel
enum PanelLayout {
    static let shadowSide: CGFloat = 32
    static let shadowTop: CGFloat = 8
    static let shadowBottom: CGFloat = 48

    static func contentSize(in window: CGSize) -> CGSize {
        CGSize(width: window.width - 2 * shadowSide, height: window.height - shadowTop - shadowBottom)
    }

    static func windowSize(for content: CGSize) -> CGSize {
        CGSize(width: content.width + 2 * shadowSide, height: content.height + shadowTop + shadowBottom)
    }

    static func windowOrigin(for content: CGPoint) -> CGPoint {
        CGPoint(x: content.x - shadowSide, y: content.y + shadowTop)
    }

    static func contentRect(in window: CGSize) -> CGRect {
        CGRect(origin: CGPoint(x: shadowSide, y: shadowBottom), size: contentSize(in: window))
    }
}

// Reject unfinished status-item layouts instead of opening at the screen origin
func panelOrigin(anchor: CGRect, screen: CGRect, visible: CGRect, size: CGSize) -> CGPoint? {
    let menuHeight = max(30, screen.maxY - visible.maxY)
    guard anchor.width > 0, anchor.height > 0,
          anchor.midX > screen.minX, anchor.midX < screen.maxX,
          anchor.midY >= screen.maxY - menuHeight - 2, anchor.maxY <= screen.maxY + 1 else { return nil }
    return CGPoint(x: min(max(anchor.minX, visible.minX + 8), visible.maxX - size.width - 8),
                   y: max(visible.minY + size.height, screen.maxY - menuHeight - 8))
}
