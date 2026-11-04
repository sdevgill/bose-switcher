import AppKit
import SwiftUI
import QuartzCore

private enum PanelStyle {
    static let strong = color(0x212124, 0xededf0)
    static let secondary = color(0x6c6c72, 0xa1a1a6)
    static let faint = color(0x96969b, 0x6f6f75)
    static let accent = color(0x0a7aff, 0x0a84ff)
    static let accentText = color(0x0a64d6, 0x6ab3ff)
    static let circle = color(0x000000, 0xffffff, lightAlpha: 0.07, darkAlpha: 0.12)
    static let line = color(0x000000, 0xffffff, lightAlpha: 0.09, darkAlpha: 0.10)
    static let glass = color(0xffffff, 0x000000, lightAlpha: 0.40, darkAlpha: 0.35)
    static let shadow = color(0x142448, 0x000000, lightAlpha: 0.34, darkAlpha: 0.70)

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
                Image(nsImage: referenceSymbol("headphones")).resizable().frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(app.headphonesName).font(.system(size: 13, weight: .semibold)).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                if app.macConnected, let battery = app.batteryPercent {
                    HStack(spacing: 4) {
                        Image(nsImage: referenceSymbol("battery", battery: battery)).resizable().frame(width: 26, height: 22)
                        Text("\(battery)%").font(.system(size: 12, weight: .regular)).fontWeight(.regular)
                    }
                    .foregroundStyle(PanelStyle.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Headphones battery")
                    .accessibilityValue("\(battery) percent")
                }
            }
            .frame(height: 40)
            .padding(.horizontal, 10)

            if let status = app.bluetoothStatus {
                Text(status).font(.system(size: 12, weight: .regular)).fontWeight(.regular)
                    .foregroundStyle(PanelStyle.secondary).padding(10)
            } else if app.macConnected {
                Text("Devices").font(.system(size: 11, weight: .semibold)).fontWeight(.semibold)
                    .foregroundStyle(PanelStyle.faint).frame(height: 22).padding(.horizontal, 10)
            } else {
                HStack(spacing: 8) {
                    Image(nsImage: referenceSymbol("warning")).resizable()
                        .frame(width: 18, height: 18).foregroundStyle(PanelStyle.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Not connected to this Mac").font(.system(size: 13, weight: .medium)).fontWeight(.medium)
                            .frame(height: 16)
                        Text("Showing last known devices").font(.system(size: 11, weight: .regular)).fontWeight(.regular)
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
                        DeviceRow(device: device, displayName: app.state.displayName(for: device), action: app.actions[device.address] ?? .idle,
                                  live: app.macConnected && app.state.isFresh(device.address), disabled: app.actionPending || app.bluetoothStatus != nil,
                                  visible: app.panelShown) { app.toggle(device) }
                    }
                    if app.state.devices.isEmpty {
                        Text(app.macConnected ? "Loading devices…" : "Connect the headphones to this Mac once to load devices.")
                            .font(.system(size: 12, weight: .regular)).fontWeight(.regular).foregroundStyle(PanelStyle.secondary).padding(10)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: app.state.devices.isEmpty ? 60 : CGFloat(min(app.state.devices.count, 10) * 38))

            Rectangle().fill(PanelStyle.line).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit").font(.system(size: 13, weight: .regular)).fontWeight(.regular)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .padding(.horizontal, 10).contentShape(Rectangle())
            }
            .buttonStyle(DeviceButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("Quit Bose Switcher")
        }
        .padding(8)
        .frame(width: 256)
        .foregroundStyle(PanelStyle.strong)
        .background {
            // The system material supplies backdrop blur, tint and the glass rim
            Color.clear
                .glassEffect(.regular.tint(PanelStyle.glass), in: .rect(cornerRadius: 22))
        }
    }
}

// Keep the shadow outside the glass to avoid darkening its content
struct PanelShadow: View {
    var body: some View {
        Canvas { context, size in
            let panel = CGRect(x: PanelLayout.shadowSide, y: PanelLayout.shadowTop,
                               width: size.width - 2 * PanelLayout.shadowSide,
                               height: size.height - PanelLayout.shadowTop - PanelLayout.shadowBottom)
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRoundedRect(in: panel, cornerSize: CGSize(width: 22, height: 22))
            context.clip(to: outside, style: FillStyle(eoFill: true))
            context.addFilter(.shadow(color: PanelStyle.shadow, radius: 22, x: 0, y: 18, options: .shadowOnly))
            context.fill(Path(roundedRect: panel.insetBy(dx: 10, dy: 10), cornerRadius: 12), with: .color(.black))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DeviceRow: View {
    let device: PairedDevice
    let displayName: String
    let action: RowAction
    let live: Bool
    let disabled: Bool
    let visible: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connected: Bool { live && device.connected }

    private var state: String {
        switch action {
        case .checking: return "checking connection"
        case .working(let disconnecting): return disconnecting ? "disconnecting" : "connecting"
        case .failed(let reason): return reason
        default: return live ? (connected ? (device.active ? "playing" : "connected") : "not connected") : "connection status unavailable"
        }
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(nsImage: referenceSymbol(device.symbol)).resizable()
                    .foregroundStyle(connected ? Color.white : PanelStyle.strong)
                    .frame(width: 18, height: 18)
                    .frame(width: 28, height: 28)
                    .background(connected ? PanelStyle.accent : PanelStyle.circle, in: Circle())
                    .overlay {
                        if action.working {
                            ProgressRing(animate: visible && !reduceMotion).frame(width: 36, height: 36)
                        }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName).font(.system(size: 13, weight: .regular)).fontWeight(.regular).lineLimit(1).frame(height: 16)
                    if case .checking = action {
                        Text("Checking…").font(.system(size: 11, weight: .regular)).fontWeight(.regular).foregroundStyle(PanelStyle.accentText).frame(height: 14)
                    } else if case .working(let disconnecting) = action {
                        Text(disconnecting ? "Disconnecting…" : "Connecting…")
                            .font(.system(size: 11, weight: .regular)).fontWeight(.regular).foregroundStyle(PanelStyle.accentText).frame(height: 14)
                    } else if case .failed(let reason) = action {
                        Text(reason).font(.system(size: 11, weight: .regular)).fontWeight(.regular).foregroundStyle(PanelStyle.secondary).frame(height: 14)
                    } else if connected {
                        Text(device.active ? "Playing" : "Connected")
                            .font(.system(size: 11, weight: .regular)).fontWeight(.regular)
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
        .buttonStyle(DeviceButtonStyle())
        .disabled(disabled)
        .accessibilityLabel(device.name)
        .accessibilityValue(state)
        .help(device.name)
    }
}

// Keep disabled rows readable during a switch
private struct DeviceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { RowHighlight(pressed: configuration.isPressed) }
    }
}

private struct RowHighlight: NSViewRepresentable {
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> RowHighlightView { RowHighlightView() }

    func updateNSView(_ view: RowHighlightView, context: Context) {
        view.pressed = pressed
        view.enabled = enabled
    }
}

// Redraw only the row's background, without publishing hover changes to SwiftUI
final class RowHighlightView: NSView {
    var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    var enabled = true { didSet { if enabled != oldValue { needsDisplay = true } } }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard enabled && (hovered || pressed) else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}

// Rotate the arc without triggering SwiftUI layout
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
        let center = CGPoint(x: 17.9793732, y: 18.0000129)
        path.addArc(center: center, radius: 16.5,
                    startAngle: atan2(34.5 - center.y, 18 - center.x),
                    endAngle: atan2(12.4 - center.y, 33.5 - center.x), clockwise: true)
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

// Template images let the system tint the artwork
func referenceSymbol(_ name: String, battery: Int = 100) -> NSImage {
    let size = name == "battery" ? NSSize(width: 26, height: 22) : NSSize(width: 22, height: 22)
    let image = NSImage(size: size, flipped: true) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.setFillColor(NSColor.black.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if name == "battery" { context.translateBy(x: 1.0 / 6, y: 0) }
        context.scaleBy(x: 11.0 / 12, y: 11.0 / 12)
        func rounded(_ rect: CGRect, _ radius: CGFloat, stroke: CGFloat? = nil) {
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            if let stroke { context.setLineWidth(stroke); context.strokePath() } else { context.fillPath() }
        }
        func line(_ points: CGPoint..., width: CGFloat) {
            guard let first = points.first else { return }
            context.beginPath()
            context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            context.setLineWidth(width)
            context.strokePath()
        }
        if name == "battery" {
            context.setAlpha(0.5)
            rounded(CGRect(x: 2, y: 7, width: 21, height: 10), 3, stroke: 1.3)
            line(CGPoint(x: 25, y: 10.3), CGPoint(x: 25, y: 13.7), width: 1.6)
            context.setAlpha(1)
            if battery > 0 { rounded(CGRect(x: 3.9, y: 8.9, width: 17.25 * Double(battery) / 100, height: 6.2), 1.5) }
        } else if name == "iphone" {
            rounded(CGRect(x: 6.75, y: 2.75, width: 10.5, height: 18.5), 2.7, stroke: 1.5)
            line(CGPoint(x: 10.6, y: 5.5), CGPoint(x: 13.4, y: 5.5), width: 1.6)
        } else if name == "laptopcomputer" {
            rounded(CGRect(x: 4, y: 5, width: 16, height: 11), 1.6, stroke: 1.5)
            line(CGPoint(x: 1.9, y: 18.7), CGPoint(x: 22.1, y: 18.7), width: 1.7)
        } else if name == "appletv" {
            context.beginPath()
            context.move(to: CGPoint(x: 6.2, y: 8.2))
            context.addLine(to: CGPoint(x: 17.8, y: 8.2))
            context.addLine(to: CGPoint(x: 20.2, y: 11.8))
            context.addLine(to: CGPoint(x: 20.2, y: 16.2))
            context.addArc(center: CGPoint(x: 18.4, y: 16.2), radius: 1.8, startAngle: 0, endAngle: .pi / 2, clockwise: false)
            context.addLine(to: CGPoint(x: 5.6, y: 18))
            context.addArc(center: CGPoint(x: 5.6, y: 16.2), radius: 1.8, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
            context.addLine(to: CGPoint(x: 3.8, y: 11.8))
            context.closePath()
            context.setLineWidth(1.5)
            context.strokePath()
            line(CGPoint(x: 3.8, y: 11.8), CGPoint(x: 20.2, y: 11.8), width: 1.5)
        } else if name == "pc" {
            rounded(CGRect(x: 2.5, y: 4.5, width: 13, height: 9.5), 1.4, stroke: 1.5)
            rounded(CGRect(x: 17.5, y: 4.5, width: 4.25, height: 13.25), 1.1, stroke: 1.5)
            line(CGPoint(x: 9, y: 14), CGPoint(x: 9, y: 17.3), width: 1.5)
            line(CGPoint(x: 6, y: 17.6), CGPoint(x: 12, y: 17.6), width: 1.5)
            line(CGPoint(x: 18.9, y: 7.4), CGPoint(x: 20.35, y: 7.4), width: 1.4)
        } else if name == "warning" {
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(x: 3.25, y: 3.25, width: 17.5, height: 17.5))
            line(CGPoint(x: 12, y: 7.4), CGPoint(x: 12, y: 13), width: 1.8)
            context.fillEllipse(in: CGRect(x: 10.85, y: 15.25, width: 2.3, height: 2.3))
        } else {
            context.saveGState()
            if name == "switcher" {
                context.translateBy(x: -1, y: -1.5)
                context.scaleBy(x: 22.0 / 24, y: 22.0 / 24)
            }
            context.beginPath()
            context.move(to: CGPoint(x: 4.4, y: 15))
            context.addLine(to: CGPoint(x: 4.4, y: 12))
            context.addArc(center: CGPoint(x: 12, y: 12), radius: 7.6, startAngle: .pi, endAngle: 0, clockwise: false)
            context.addLine(to: CGPoint(x: 19.6, y: 15))
            context.setLineWidth(1.7)
            context.strokePath()
            rounded(CGRect(x: 2.6, y: 12.6, width: 4.8, height: 8.4), 2.2)
            rounded(CGRect(x: 16.6, y: 12.6, width: 4.8, height: 8.4), 2.2)
            context.restoreGState()
            if name == "switcher" {
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 12, y: 11.8, width: 13.2, height: 13.2))
                context.setBlendMode(.normal)
                line(CGPoint(x: 22.3, y: 16.2), CGPoint(x: 15.1, y: 16.2), width: 1.55)
                line(CGPoint(x: 17, y: 14.3), CGPoint(x: 15.1, y: 16.2), CGPoint(x: 17, y: 18.1), width: 1.55)
                line(CGPoint(x: 15, y: 20.6), CGPoint(x: 22.2, y: 20.6), width: 1.55)
                line(CGPoint(x: 20.3, y: 18.7), CGPoint(x: 22.2, y: 20.6), CGPoint(x: 20.3, y: 22.5), width: 1.55)
            }
        }
        return true
    }
    image.isTemplate = true
    return image
}

func switcherIcon() -> NSImage {
    let image = referenceSymbol("switcher")
    image.accessibilityDescription = "Bose Switcher"
    return image
}
