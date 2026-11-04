import AppKit
import SwiftUI
import IOBluetooth
import CoreBluetooth

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject, CBCentralManagerDelegate {
    private(set) var state = DeviceState()
    @Published var actions: [[UInt8]: RowAction] = [:]
    @Published var macConnected = false
    @Published var headphonesName = UserDefaults.standard.string(forKey: "headphonesName") ?? "Headphones"
    @Published var actionPending = false
    @Published var panelShown = false
    @Published var batteryPercent: Int?
    @Published var bluetoothStatus: String? = "Loading Bluetooth…"
    private var central: CBCentralManager!
    private let statusItem = NSStatusBar.system.statusItem(withLength: 36)
    private let statusLabel = StatusLabel()
    private let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var panelTopLeft = NSPoint.zero

    private let bluetooth = BluetoothThread()
    private var refreshPending = false
    private var refreshAgain = false
    private var refreshListAgain = false
    private var lastList = Date.distantPast
    private var panelTimer: Timer?
    private var cacheSave: DispatchWorkItem?
    private var listNeeded = true
    private var completedActions: [[UInt8]: UUID] = [:]
    // Only the Bluetooth thread touches the link
    private var link: BmapLink?
    private var temporaryMac = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = UserDefaults.standard.data(forKey: "devices") {
            let saved = (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
            state.devices = saved.filter { $0.symbol == "laptopcomputer" } + saved.filter { $0.symbol == "appletv" } +
                saved.filter { $0.symbol != "laptopcomputer" && $0.symbol != "appletv" }
        }
        if let button = statusItem.button {
            statusLabel.frame = button.bounds
            statusLabel.autoresizingMask = [.width, .height]
            button.addSubview(statusLabel)
            button.setAccessibilityLabel("Bose Switcher")
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.toolTip = "Bose Switcher"
        panel.delegate = self
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: SwitcherPanel(app: self)
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { self.resizePanel($0) }))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.cornerRadius = 22
        view.layer?.masksToBounds = true
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        bluetooth.start()
        if CBManager.authorization == .notDetermined { bluetoothStatus = "Allow Bluetooth access…" }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    @objc private func togglePanel() {
        if panelShown { hidePanel(); return }
        guard let button = statusItem.button else { return }
        let anchor = button.accessibilityFrame()
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        panelTopLeft = NSPoint(x: min(max(anchor.minX, visible.minX + 8), visible.maxX - 264),
                               y: min(anchor.minY - 8, screen.frame.maxY - 38))
        panel.setFrameTopLeftPoint(panelTopLeft)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        button.toolTip = nil
        statusLabel.selected = true
        showPanel()
    }

    private func resizePanel(_ size: CGSize) {
        guard size.width > 0, size.height > 0, panel.frame.size != size else { return }
        panel.setContentSize(size)
        if panelShown { panel.setFrameTopLeftPoint(panelTopLeft) }
    }

    func windowDidResignKey(_ notification: Notification) { hidePanel() }

    // Ask asynchronously before entering IOBluetooth's blocking permission wait
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = nil
            requestRefresh(list: state.devices.isEmpty)
        case .unauthorized:
            bluetoothStatus = "Allow Bluetooth in System Settings"
        case .poweredOff:
            bluetoothStatus = "Bluetooth is turned off"
            macConnected = false
            batteryPercent = nil
        case .unsupported: bluetoothStatus = "Bluetooth is unavailable"
        default: bluetoothStatus = CBManager.authorization == .notDetermined ? "Allow Bluetooth access…" : "Loading Bluetooth…"
        }
    }

    func showPanel() {
        panelShown = true
        if panelTimer == nil {
            requestRefresh(list: state.devices.isEmpty)
            panelTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, !self.actionPending else { return }
                self.requestRefresh(list: Date().timeIntervalSince(self.lastList) >= 60)
            }
        }
    }

    func hidePanel() {
        guard panelShown else { return }
        panelShown = false
        panel.orderOut(nil)
        statusLabel.selected = false
        statusItem.button?.toolTip = "Bose Switcher"
        panelTimer?.invalidate()
        panelTimer = nil
    }

    // A cached launch starts with Info, then discovers new pairings at idle priority
    private func requestRefresh(list: Bool = false) {
        guard bluetoothStatus == nil else { return }
        guard !refreshPending else {
            refreshAgain = true
            refreshListAgain = refreshListAgain || list
            return
        }
        refreshPending = true
        if list { lastList = Date() }
        let known = state.knownAddresses
        bluetooth.async {
            let headphones = findHeadphones()
            let connected = headphones?.isConnected() ?? false
            self.publishConnection(headphones, connected: connected)
            var order: [[UInt8]]?
            if connected, !self.bluetooth.actionQueued, let headphones, let link = self.openLink(headphones) {
                order = link.refresh(known, list: list, yielding: { self.bluetooth.actionQueued })
            }
            let discovered = order
            DispatchQueue.main.async {
                if discovered != nil {
                    self.listNeeded = false
                    self.lastList = Date()
                }
                self.refreshPending = false
                let again = self.refreshAgain
                let nextList = self.refreshListAgain || (connected && self.listNeeded && !list && Date().timeIntervalSince(self.lastList) >= 60)
                self.refreshAgain = false
                self.refreshListAgain = false
                if (again || nextList) && !self.actionPending {
                    self.requestRefresh(list: nextList)
                }
            }
        }
    }

    private func openLink(_ headphones: IOBluetoothDevice) -> BmapLink? {
        if let link, link.isOpen { return link }
        link = BmapLink(device: headphones)
        link?.onDevice = { reading in
            DispatchQueue.main.async {
                self.updateState { $0.merge(reading) }
            }
        }
        let computer = macAddress()
        link?.onList = { addresses in
            DispatchQueue.main.async {
                // Pairing responses can change order after a switch, but visible rows must not
                let televisions = self.state.devices.filter { $0.symbol == "appletv" }.map(\.address)
                let previous = self.state.knownAddresses.filter { addresses.contains($0) }
                let stable = previous + addresses.filter { !previous.contains($0) }
                let ordered = stable.filter { $0 == computer } + stable.filter { televisions.contains($0) && $0 != computer } +
                    stable.filter { $0 != computer && !televisions.contains($0) }
                self.updateState { $0.reorder(ordered) }
                self.actions = self.actions.filter { addresses.contains($0.key) }
                self.completedActions = self.completedActions.filter { addresses.contains($0.key) }
            }
        }
        link?.onBattery = { level in
            DispatchQueue.main.async { if self.batteryPercent != level { self.batteryPercent = level } }
        }
        link?.onClose = {
            let headphones = findHeadphones()
            self.publishConnection(headphones, connected: headphones?.isConnected() ?? false)
        }
        return link
    }

    // Mac connectivity does not depend on whether any Info requests answered
    private func publishConnection(_ headphones: IOBluetoothDevice?, connected: Bool) {
        let name = headphones?.name
        let address = macAddress()
        DispatchQueue.main.async {
            if let name, !name.isEmpty, name != self.headphonesName {
                self.headphonesName = name
                UserDefaults.standard.set(name, forKey: "headphonesName")
            }
            if self.macConnected != connected {
                self.macConnected = connected
                if connected {
                    self.listNeeded = true
                    self.lastList = .distantPast
                }
                if !connected { self.batteryPercent = nil }
                self.updateState {
                    $0.invalidateReadings()
                    $0.confirm(address, connected: connected)
                }
            }
        }
    }

    func toggle(_ target: PairedDevice) {
        guard !actionPending, bluetoothStatus == nil, state.knownAddresses.contains(target.address) else { return }
        let disconnecting = macConnected && target.connected
        let needsReading = macConnected && !state.isFresh(target.address)
        actionPending = true
        completedActions[target.address] = nil
        actions[target.address] = needsReading ? .checking : .working(disconnecting: disconnecting)
        bluetooth.async(action: true) { self.send(target, disconnecting: disconnecting, needsReading: needsReading) }
    }

    private func send(_ target: PairedDevice, disconnecting: Bool, needsReading: Bool) {
        var disconnecting = disconnecting
        guard let headphones = findHeadphones() else {
            finish(target, disconnecting: disconnecting, result: .timeout)
            return
        }
        let address = macAddress()
        let isMac = target.address == address
        let macWasConnected = headphones.isConnected()
        if !macWasConnected && headphones.openConnection() != kIOReturnSuccess {
            finish(target, disconnecting: disconnecting, result: .timeout)
            return
        }
        if !macWasConnected { temporaryMac = true }
        defer {
            if temporaryMac && !isMac && !bluetooth.actionQueued {
                // Return a borrowed slot even if Info or the command channel failed
                let closed = headphones.closeConnection() == kIOReturnSuccess
                let deadline = Date(timeIntervalSinceNow: 3)
                while closed && headphones.isConnected() && Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
                }
                temporaryMac = false
                publishConnection(headphones, connected: headphones.isConnected())
                if !closed || headphones.isConnected() {
                    DispatchQueue.main.async { self.actions[address] = .failed(reason: "Couldn't disconnect") }
                }
            }
        }
        publishConnection(headphones, connected: true)
        if isMac && !disconnecting {
            temporaryMac = false
            finish(target, disconnecting: false, result: .confirmed)
            return
        }
        guard let link = openLink(headphones) else {
            publishConnection(headphones, connected: findHeadphones()?.isConnected() ?? false)
            finish(target, disconnecting: disconnecting, result: .timeout)
            return
        }
        if needsReading && !isMac {
            guard let reading = link.readDevice(target.address) else {
                finish(target, disconnecting: disconnecting, result: .timeout)
                return
            }
            disconnecting = reading.connected
            let resolved = disconnecting
            DispatchQueue.main.async { self.actions[target.address] = .working(disconnecting: resolved) }
        }
        if isMac {
            let result = link.disconnectHost(address, isConnected: { headphones.isConnected() })
            temporaryMac = false
            publishConnection(headphones, connected: headphones.isConnected())
            finish(target, disconnecting: true, result: result)
            return
        }
        let began = Date()
        let reply = disconnecting
            ? link.request(disconnect, start, target.address)
            : link.request(connect, start, [0] + target.address)
        let result: ActionResult
        if reply?.operation == failed {
            result = .refused
        } else if reply == nil {
            result = .timeout
        } else {
            result = disconnecting ? .confirmed : link.waitUntilConnected(target.address, since: began)
        }
        // Publish and unlock before giving the Mac's temporary slot back
        finish(target, disconnecting: disconnecting, result: result)
    }

    private func finish(_ target: PairedDevice, disconnecting: Bool, result: ActionResult) {
        DispatchQueue.main.sync {
            switch result {
            case .confirmed:
                self.updateState { $0.confirm(target.address, connected: !disconnecting) }
                self.actions[target.address] = .confirmed
            case .refused:
                self.actions[target.address] = .failed(reason: disconnecting ? "Couldn't disconnect" : "Couldn't connect")
                NSSound.beep()
            case .timeout:
                self.actions[target.address] = .failed(reason: "No answer")
            }
            self.actionPending = false
            let completion = UUID()
            self.completedActions[target.address] = completion
            self.requestRefresh(list: self.state.devices.isEmpty)
            // Wait out the measured Info lag without occupying the Bluetooth thread
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.completedActions[target.address] == completion { self.actions[target.address] = .idle }
                self.requestRefresh(list: self.state.devices.isEmpty)
            }
        }
    }

    private func updateState(_ change: (inout DeviceState) -> Void) {
        var updated = state
        change(&updated)
        let changed = updated.devices != state.devices || updated.devices.contains { updated.isFresh($0.address) != state.isFresh($0.address) }
        if changed { objectWillChange.send() }
        state = updated
        guard changed else { return }
        cacheSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(self.state.devices), forKey: "devices")
        }
        cacheSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: save)
    }
}

@main
struct BoseSwitcher {
    static func main() {
        if CommandLine.arguments.contains("--scan") {
            let serviceUUID: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0xde, 0xca, 0xfa, 0xde, 0xde, 0xca, 0xde, 0xaf, 0xde, 0xca, 0xca, 0xff]
            let uuid = IOBluetoothSDPUUID(bytes: serviceUUID, length: serviceUUID.count)
            let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            print(paired.first { $0.getServiceRecord(for: uuid) != nil }?.addressString ?? "")
            return
        }
        let application = NSApplication.shared
        let delegate = App()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (delegate as? App)?.hidePanel() }
}
