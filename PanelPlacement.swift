import Foundation
import CoreGraphics

// Reject unfinished status-item layouts instead of opening at the screen origin
func panelOrigin(anchor: CGRect, screen: CGRect, visible: CGRect, size: CGSize) -> CGPoint? {
    let menuHeight = max(30, screen.maxY - visible.maxY)
    guard anchor.width > 0, anchor.height > 0,
          anchor.midX > screen.minX, anchor.midX < screen.maxX,
          anchor.midY >= screen.maxY - menuHeight - 2, anchor.maxY <= screen.maxY + 1 else { return nil }
    return CGPoint(x: min(max(anchor.minX, visible.minX + 8), visible.maxX - size.width - 8),
                   y: max(visible.minY + size.height, screen.maxY - menuHeight - 8))
}
