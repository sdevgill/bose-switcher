import AppKit
import SwiftUI
import QuartzCore

// Colors from the E stills, while the surface itself uses system glass
private enum PanelStyle {
    static let strong = color(0x212124, 0xededf0)
    static let secondary = color(0x6c6c72, 0xa1a1a6)
    static let faint = color(0x96969b, 0x6f6f75)
    static let accent = color(0x0a7aff, 0x0a84ff)
    static let accentText = color(0x0a64d6, 0x6ab3ff)
    static let circle = color(0x000000, 0xffffff, lightAlpha: 0.07, darkAlpha: 0.12)
    static let line = color(0x000000, 0xffffff, lightAlpha: 0.09, darkAlpha: 0.10)

    private static func color(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

struct SwitcherPanel: View {
    @ObservedObject var app: App

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "headphones").font(.system(size: 16)).frame(width: 18)
                    .accessibilityHidden(true)
                Text(app.headphonesName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if app.macConnected, let battery = app.batteryPercent {
                    HStack(spacing: 4) {
                        Image(systemName: "battery.100percent", variableValue: Double(battery) / 100)
                            .font(.system(size: 17)).frame(width: 26, height: 22)
                        Text("\(battery)%").font(.system(size: 12))
                    }
                    .foregroundStyle(PanelStyle.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Headphones battery")
                    .accessibilityValue("\(battery) percent")
                }
            }
            .frame(height: 40)
            .padding(.horizontal, 10)

            if app.macConnected {
                Text("Devices").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanelStyle.faint).frame(height: 22).padding(.horizontal, 10)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 14))
                        .frame(width: 18).foregroundStyle(PanelStyle.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Not connected to this Mac").font(.system(size: 13, weight: .medium))
                            .frame(height: 16)
                        Text("Showing last known devices").font(.system(size: 11))
                            .foregroundStyle(PanelStyle.secondary).frame(height: 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(PanelStyle.circle, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 5)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(app.state.devices) { device in
                        DeviceRow(device: device, action: app.actions[device.address] ?? .idle,
                                  live: app.macConnected, disabled: app.actionPending,
                                  visible: app.panelShown) { app.toggle(device) }
                    }
                    if app.state.devices.isEmpty {
                        Text("Connect the headphones to this Mac once to load devices.")
                            .font(.system(size: 12)).foregroundStyle(PanelStyle.secondary).padding(10)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: app.state.devices.isEmpty ? 60 : CGFloat(min(app.state.devices.count, 10) * 38))

            Rectangle().fill(PanelStyle.line).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit").font(.system(size: 13))
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .padding(.horizontal, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("Quit Bose Switcher")
        }
        .padding(8)
        .frame(width: 256)
        .foregroundStyle(PanelStyle.strong)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private struct DeviceRow: View {
    let device: PairedDevice
    let action: RowAction
    let live: Bool
    let disabled: Bool
    let visible: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connected: Bool { live && device.connected }

    private var state: String {
        switch action {
        case .working(let disconnecting): return disconnecting ? "disconnecting" : "connecting"
        case .failed(let reason): return reason
        default: return connected ? (device.active ? "playing" : "connected") : "not connected"
        }
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(connected ? Color.white : PanelStyle.strong)
                    .frame(width: 28, height: 28)
                    .background(connected ? PanelStyle.accent : PanelStyle.circle, in: Circle())
                    .overlay {
                        if action.working {
                            ProgressRing(animate: visible && !reduceMotion).frame(width: 36, height: 36)
                        }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.displayName).font(.system(size: 13)).lineLimit(1).frame(height: 16)
                    if case .working(let disconnecting) = action {
                        WorkingLabel(disconnecting: disconnecting, animate: visible && !reduceMotion)
                    } else if case .failed(let reason) = action {
                        Text(reason).font(.system(size: 11)).foregroundStyle(PanelStyle.secondary).frame(height: 14)
                    } else if connected {
                        Text(device.active ? "Playing" : "Connected")
                            .font(.system(size: 11))
                            .foregroundStyle(device.active ? PanelStyle.accentText : PanelStyle.secondary)
                            .frame(height: 14)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.name)
        .accessibilityValue(state)
    }
}

private struct WorkingLabel: View {
    let disconnecting: Bool
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3, paused: !animate)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 0) {
                Text(disconnecting ? "Disconnecting" : "Connecting")
                ForEach(0..<3) { index in Text(".").opacity(!animate || index <= phase ? 1 : 0.25) }
            }
            .font(.system(size: 11)).foregroundStyle(PanelStyle.accentText).frame(height: 14)
        }
    }
}

// Core Animation rotates only the arc, with no per-frame SwiftUI layout or timers
private struct ProgressRing: NSViewRepresentable {
    let animate: Bool

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) { view.setAnimating(animate) }

    static func dismantleNSView(_ view: RingView, coordinator: ()) { view.setAnimating(false) }
}

private final class RingView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        wantsLayer = true
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            shape.fillColor = nil
            shape.lineWidth = 2
            layer?.addSublayer(shape)
        }
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: 18, y: 18), radius: 16.5,
                    startAngle: .pi / 2, endAngle: -.pi / 9, clockwise: true)
        arc.path = path
        arc.lineCap = .round
        updateColors()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor(PanelStyle.line).cgColor
            arc.strokeColor = NSColor(PanelStyle.accent).cgColor
        }
    }

    func setAnimating(_ animate: Bool) {
        guard animate else {
            arc.removeAnimation(forKey: "rotation")
            return
        }
        guard arc.animation(forKey: "rotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -Double.pi * 2
        rotation.duration = 1
        rotation.repeatCount = .infinity
        arc.add(rotation, forKey: "rotation")
    }
}

// One template image lets macOS tint the headphones and switching badge together
func switcherIcon() -> NSImage {
    let headphones = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)!
    let arrows = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))!
    let image = NSImage(size: NSSize(width: 23, height: 18), flipped: false) { _ in
        headphones.draw(in: NSRect(x: 0, y: 1, width: 17, height: 17))
        // Clear space behind the badge without baking in a menu bar color
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: NSRect(x: 11, y: 0, width: 12, height: 9), xRadius: 2, yRadius: 2).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        arrows.draw(in: NSRect(x: 12, y: 1, width: 10, height: 7))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Bose Switcher"
    return image
}
