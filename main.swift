import AppKit
import SwiftUI
import IOBluetooth
import CoreBluetooth

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSStatusItemExpandedInterfaceDelegate, ObservableObject, CBCentralManagerDelegate {
    private(set) var state = DeviceState()
    @Published var actions: [[UInt8]: RowAction] = [:]
    @Published var macConnected = false
    @Published var headphonesName = UserDefaults.standard.string(forKey: "headphonesName") ?? "Headphones"
    @Published var actionPending = false
    @Published var panelShown = false
    @Published var batteryPercent: Int?
    @Published var bluetoothStatus: String? = "Loading Bluetooth…"
    private var central: CBCentralManager!
    private lazy var statusItem = makeStatusItem()
    private let makeStatusItem: () -> NSStatusItem
    private let hostAddress: () -> [UInt8]
    private let discoverHeadphones: (() -> Bool) -> IOBluetoothDevice?
    private let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var panelTopLeft = NSPoint.zero
    private var placementTimer: Timer?
    private var outsideClickMonitor: Any?
    private var frontApp: NSRunningApplication?
    private var ignoreSessionUntil = Date.distantPast

    private let bluetooth = BluetoothThread()
    private let session = WorkSession()
    private var linkSession = -1
    private var selectedHeadphones: String?
    private var refreshPending = false
    private var refreshingList = false
    private var refreshAgain = false
    private var refreshListAgain = false
    private var lastList = Date.distantPast
    private var nextListAttempt = Date.distantPast
    private var panelTimer: Timer?
    private var cacheSave: DispatchWorkItem?
    private var listNeeded = true
    private var completedActions: [[UInt8]: UUID] = [:]
    private var displayedFresh: Set<[UInt8]> = []
    private var terminating = false
    // Only the Bluetooth thread touches the link
    private var link: BmapLink?
    private var temporaryMac: IOBluetoothDevice?

    init(hostAddress: @escaping () -> [UInt8] = macAddress,
         discoverHeadphones: @escaping (() -> Bool) -> IOBluetoothDevice? = { cancelled in
             findHeadphones(scan: { headphoneScans.run(cancelled: cancelled) { scanHeadphones(cancelled: cancelled) } })
         },
         makeStatusItem: @escaping () -> NSStatusItem = { NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }) {
        self.hostAddress = hostAddress
        self.discoverHeadphones = discoverHeadphones
        self.makeStatusItem = makeStatusItem
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.string(forKey: "deviceCacheHeadphones") == nil {
            UserDefaults.standard.set(UserDefaults.standard.string(forKey: "headphones"), forKey: "deviceCacheHeadphones")
        }
        if let data = UserDefaults.standard.data(forKey: "devices") {
            let saved = (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
            state.devices = saved
        }
        if let button = statusItem.button {
            button.image = switcherIcon()
            button.setAccessibilityLabel("Bose Switcher")
        }
        // The menu bar system owns clicks, keyboard navigation and the highlight through this session
        statusItem.expandedInterfaceDelegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.toolTip = "Bose Switcher"
        panel.delegate = self
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: SwitcherPanel(app: self)
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { self.resizePanel($0) })
            .padding(EdgeInsets(top: PanelLayout.shadowTop, leading: PanelLayout.shadowSide,
                                bottom: PanelLayout.shadowBottom, trailing: PanelLayout.shadowSide))
            .background { PanelShadow() })
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        bluetooth.start()
        if CBManager.authorization == .notDetermined { bluetoothStatus = "Allow Bluetooth access…" }
        central = CBCentralManager(delegate: self, queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(otherAppActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // A display change can move the item, so close rather than leave the panel in the wrong place
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // A real click starts a session, which keeps the item highlighted while the panel is open
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        if Date() < ignoreSessionUntil { session.cancel(); return }
        openPanel()
    }

    // Real clicks go through the session, so only accessibility presses reach this action
    @objc private func togglePanel() {
        if panelShown || placementTimer != nil { hidePanel() } else { openPanel() }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        hidePanel()
    }

    private func openPanel() {
        guard !panelShown, placementTimer == nil else { return }
        if positionPanel() { presentPanel() }
        // Accessibility can expose the status item before its window is positioned
        let deadline = Date(timeIntervalSinceNow: 2)
        placementTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let previous = self.panelTopLeft
            let placed = self.positionPanel()
            if placed && !self.panelShown { self.presentPanel() }
            // Stop once the item has settled so the timer does not run for the full deadline
            if placed && self.panelShown && self.panelTopLeft == previous {
                timer.invalidate()
                self.placementTimer = nil
            } else if Date() >= deadline {
                timer.invalidate()
                self.placementTimer = nil
                if !self.panelShown { self.hidePanel() }
            }
        }
    }

    private func positionPanel() -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        var anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let accessible = button.accessibilityFrame()
        if abs(accessible.midX - anchor.midX) < 2 { anchor.origin.x = accessible.minX }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }),
              let origin = panelOrigin(anchor: anchor, screen: screen.frame, visible: screen.visibleFrame,
                                       size: PanelLayout.contentSize(in: panel.frame.size)) else { return false }
        panelTopLeft = PanelLayout.windowOrigin(for: origin)
        panel.setFrameTopLeftPoint(panelTopLeft)
        return true
    }

    private func presentPanel() {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        statusItem.button?.toolTip = nil
        // Clicks outside the panel, including a second click on the item, go to other processes
        // The session ends on neither, so the app closes the panel itself
        frontApp = NSWorkspace.shared.frontmostApplication
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self else { return }
            // Without a session, a click on the item would start one and reopen the panel
            if self.statusItem.expandedInterfaceSession == nil { self.ignoreSessionUntil = Date(timeIntervalSinceNow: 0.5) }
            self.hidePanel()
        }
        showPanel()
    }

    private func resizePanel(_ size: CGSize) {
        let windowSize = PanelLayout.windowSize(for: size)
        guard size.width > 0, size.height > 0, panel.frame.size != windowSize else { return }
        panel.setContentSize(windowSize)
        if panelShown { panel.setFrameTopLeftPoint(panelTopLeft) }
    }

    @objc private func otherAppActivated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        // Clicking the menu bar can reactivate the front app, which must not close the panel
        if app != frontApp { hidePanel() }
    }

    @objc private func screensChanged() { hidePanel() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !terminating { beginTermination { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }

    // Let cancelled work release its borrowed connection, with a hard deadline for blocked system calls
    private func beginTermination(completion: @escaping () -> Void) {
        terminating = true
        hidePanel()
        session.begin(available: false)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var replied = false
        let finish = {
            guard !replied else { return }
            replied = true
            completion()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: finish)
        bluetooth.async(action: true) {
            let borrowed = self.temporaryMac
            borrowed?.closeConnection()
            self.temporaryMac = nil
            self.link?.close()
            self.link = nil
            while borrowed?.isConnected() == true && ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            DispatchQueue.main.async(execute: finish)
        }
    }

    // Ask asynchronously before entering IOBluetooth's blocking permission wait
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !terminating else { return }
        endSession(available: central.state == .poweredOn)
        switch central.state {
        case .poweredOn:
            bluetoothStatus = nil
            requestRefresh(list: state.devices.isEmpty)
        case .unauthorized:
            bluetoothStatus = "Allow Bluetooth in System Settings…"
        case .poweredOff:
            bluetoothStatus = "Turn on Bluetooth…"
            macConnected = false
            batteryPercent = nil
        case .unsupported: bluetoothStatus = "Bluetooth is unavailable"
        default: bluetoothStatus = CBManager.authorization == .notDetermined ? "Allow Bluetooth access…" : "Loading Bluetooth…"
        }
    }

    // Settings page for a status the user has to fix outside the app
    var bluetoothSettingsURL: URL? {
        switch central?.state {
        case .unauthorized: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        case .poweredOff: URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")
        default: nil
        }
    }

    @objc private func willSleep() { endSession(available: false) }

    @objc private func didWake() { centralManagerDidUpdateState(central) }

    private func endSession(available: Bool) {
        session.begin(available: available)
        refreshPending = false
        refreshingList = false
        refreshAgain = false
        refreshListAgain = false
        listNeeded = true
        lastList = .distantPast
        nextListAttempt = .distantPast
        macConnected = false
        batteryPercent = nil
        updateState { $0.invalidateReadings() }
        for address in actions.keys where actions[address]?.working == true {
            actions[address] = .failed(reason: "Connection interrupted")
            clearFeedback(address)
        }
        actionPending = false
        bluetooth.async(action: true) {
            self.link?.close()
            self.link = nil
            self.temporaryMac?.closeConnection()
            self.temporaryMac = nil
        }
    }

    func showPanel() {
        panelShown = true
        if panelTimer == nil {
            requestRefresh(list: state.devices.isEmpty)
            panelTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.updateState { _ in }
                guard !self.actionPending else { return }
                self.requestRefresh(list: self.shouldRefreshList)
            }
        }
    }

    func hidePanel() {
        placementTimer?.invalidate()
        placementTimer = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        // The menu bar keeps the item highlighted until the session ends
        statusItem.expandedInterfaceSession?.cancel()
        guard panelShown else { return }
        panelShown = false
        panel.orderOut(nil)
        statusItem.button?.toolTip = "Bose Switcher"
        panelTimer?.invalidate()
        panelTimer = nil
    }

    private var shouldRefreshList: Bool {
        Date() >= nextListAttempt && (listNeeded || Date().timeIntervalSince(lastList) >= 60)
    }

    // Read cached devices first, then discover new pairings at idle priority
    private func requestRefresh(list: Bool = false) {
        guard bluetoothStatus == nil, session.accepts(session.current) else { return }
        guard !refreshPending else {
            refreshAgain = !refreshingList
            refreshListAgain = refreshListAgain || (list && !refreshingList)
            return
        }
        refreshPending = true
        refreshingList = list
        let generation = session.current
        if list { nextListAttempt = Date(timeIntervalSinceNow: 5) }
        let known = state.knownAddresses
        bluetooth.async {
            guard self.session.accepts(generation) else { return }
            let headphones = self.discoverHeadphones { self.bluetooth.actionQueued || !self.session.accepts(generation) }
            let connected = headphones?.isConnected() ?? false
            let previous = UserDefaults.standard.string(forKey: "deviceCacheHeadphones")
            let replaced = previous != nil && headphones?.addressString != previous
            self.publishConnection(headphones, connected: connected, generation: generation)
            var order: [[UInt8]]?
            if connected, !self.bluetooth.actionQueued, let headphones, let link = self.openLink(headphones, generation: generation) {
                order = link.refresh(replaced ? [] : known, list: list || replaced,
                                     yielding: { self.bluetooth.actionQueued || !self.session.accepts(generation) })
            }
            let discovered = order
            DispatchQueue.main.async {
                guard self.session.accepts(generation) else { return }
                if discovered != nil {
                    self.listNeeded = false
                    self.lastList = Date()
                } else if list {
                    self.nextListAttempt = Date(timeIntervalSinceNow: 5)
                }
                self.refreshPending = false
                self.refreshingList = false
                let again = self.refreshAgain
                let nextList = self.refreshListAgain || (connected && self.shouldRefreshList && !list)
                self.refreshAgain = false
                self.refreshListAgain = false
                if (again || nextList) && !self.actionPending {
                    self.requestRefresh(list: nextList)
                }
            }
        }
    }

    private func openLink(_ headphones: IOBluetoothDevice, generation: Int) -> BmapLink? {
        guard session.accepts(generation) else { return nil }
        if let link, link.isOpen, linkSession == generation, selectedHeadphones == headphones.addressString { return link }
        link?.close()
        linkSession = generation
        selectedHeadphones = headphones.addressString
        link = BmapLink(device: headphones)
        link?.onDevice = { reading in
            DispatchQueue.main.async {
                guard self.session.accepts(generation) else { return }
                self.updateState { $0.merge(reading) }
            }
        }
        let computer = hostAddress()
        link?.onList = { addresses in
            DispatchQueue.main.async {
                guard self.session.accepts(generation) else { return }
                self.updateState { $0.reconcileOrder(addresses, computer: computer) }
                self.actions = self.actions.filter { addresses.contains($0.key) }
                self.completedActions = self.completedActions.filter { addresses.contains($0.key) }
            }
        }
        link?.onBattery = { level in
            DispatchQueue.main.async {
                guard self.session.accepts(generation), self.macConnected else { return }
                if self.batteryPercent != level { self.batteryPercent = level }
            }
        }
        link?.onClose = {
            guard self.session.accepts(generation) else { return }
            let headphones = self.discoverHeadphones { self.bluetooth.actionQueued || !self.session.accepts(generation) }
            self.publishConnection(headphones, connected: headphones?.isConnected() ?? false, generation: generation)
        }
        return link
    }

    // Track the Mac connection even when Info requests fail
    private func publishConnection(_ headphones: IOBluetoothDevice?, connected: Bool, generation: Int) {
        let name = headphones?.name
        let address = hostAddress()
        let identity = headphones?.addressString
        DispatchQueue.main.async {
            guard self.session.accepts(generation) else { return }
            if let identity, identity != UserDefaults.standard.string(forKey: "deviceCacheHeadphones") {
                self.batteryPercent = nil
                let previous = UserDefaults.standard.string(forKey: "deviceCacheHeadphones")
                UserDefaults.standard.set(identity, forKey: "deviceCacheHeadphones")
                if previous != nil {
                    self.updateState { $0 = DeviceState() }
                    self.actions = [:]
                    self.completedActions = [:]
                    self.listNeeded = true
                    if !self.refreshingList { self.lastList = .distantPast }
                }
            }
            if let name, !name.isEmpty, name != self.headphonesName {
                self.headphonesName = name
                UserDefaults.standard.set(name, forKey: "headphonesName")
            }
            if self.macConnected != connected {
                self.macConnected = connected
                if connected {
                    self.listNeeded = true
                    if !self.refreshingList { self.lastList = .distantPast }
                }
                if !connected { self.batteryPercent = nil }
                if !connected, self.actions[address] == .failed(reason: "Couldn't disconnect") {
                    self.actions[address] = .idle
                    self.completedActions[address] = nil
                }
                self.updateState {
                    $0.invalidateReadings()
                    $0.confirm(address, connected: connected)
                }
            }
        }
    }

    func toggle(_ target: PairedDevice) {
        guard !actionPending, bluetoothStatus == nil, state.knownAddresses.contains(target.address) else { return }
        let generation = session.current
        guard session.accepts(generation), let target = state.devices.first(where: { $0.address == target.address }) else { return }
        let disconnecting = macConnected && target.connected
        let needsReading = target.address != hostAddress() && macConnected && !state.isFresh(target.address)
        actionPending = true
        completedActions[target.address] = UUID()
        let cleanupOwner = completedActions[hostAddress()]
        actions[target.address] = needsReading ? .checking : .working(disconnecting: disconnecting)
        bluetooth.async(action: true) { self.send(target, disconnecting: disconnecting, needsReading: needsReading, cleanupOwner: cleanupOwner, generation: generation) }
    }

    private func send(_ target: PairedDevice, disconnecting: Bool, needsReading: Bool, cleanupOwner: UUID?, generation: Int) {
        guard session.accepts(generation) else { return }
        var disconnecting = disconnecting
        guard let headphones = discoverHeadphones({ !self.session.accepts(generation) }) else {
            finish(target, disconnecting: disconnecting, result: .timeout, generation: generation)
            return
        }
        let address = hostAddress()
        let isMac = target.address == address
        let macWasConnected = headphones.isConnected()
        let previous = UserDefaults.standard.string(forKey: "deviceCacheHeadphones")
        if let previous, previous != headphones.addressString {
            publishConnection(headphones, connected: macWasConnected, generation: generation)
            finish(target, disconnecting: disconnecting, result: .timeout, generation: generation)
            return
        }
        if isMac { disconnecting = macWasConnected }
        guard session.accepts(generation) else { return }
        if !macWasConnected && headphones.openConnection() != kIOReturnSuccess {
            finish(target, disconnecting: disconnecting, result: .timeout, generation: generation)
            return
        }
        if !macWasConnected { temporaryMac = headphones }
        defer {
            if let borrowed = temporaryMac, (!isMac || !session.accepts(generation)),
               (!session.accepts(generation) || !bluetooth.actionQueued) {
                // Return a borrowed slot even if Info or the command channel failed
                let closed = borrowed.closeConnection() == kIOReturnSuccess
                let deadline = Date(timeIntervalSinceNow: 3)
                while closed && session.accepts(generation) && borrowed.isConnected() && Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
                }
                if session.accepts(generation) || !borrowed.isConnected() { temporaryMac = nil }
                publishConnection(borrowed, connected: borrowed.isConnected(), generation: generation)
                if !closed || borrowed.isConnected() {
                    DispatchQueue.main.async {
                        self.publishCleanupFailure(address, owner: cleanupOwner, generation: generation)
                    }
                }
            }
        }
        guard session.accepts(generation) else { return }
        publishConnection(headphones, connected: true, generation: generation)
        if isMac && !disconnecting {
            temporaryMac = nil
            finish(target, disconnecting: false, result: .confirmed, generation: generation)
            return
        }
        guard let link = openLink(headphones, generation: generation) else {
            publishConnection(headphones, connected: headphones.isConnected(), generation: generation)
            finish(target, disconnecting: disconnecting, result: .timeout, generation: generation)
            return
        }
        guard session.accepts(generation) else { return }
        let latest = DispatchQueue.main.sync {
            (fresh: self.state.isFresh(target.address), connected: self.state.devices.first { $0.address == target.address }?.connected)
        }
        if !isMac, let connected = latest.connected { disconnecting = connected }
        let needsReading = needsReading || !latest.fresh
        if needsReading && !isMac {
            guard let reading = link.readDevice(target.address, cancelled: { !self.session.accepts(generation) }) else {
                finish(target, disconnecting: disconnecting, result: .timeout, generation: generation)
                return
            }
            disconnecting = reading.connected
        }
        if !isMac {
            let resolved = disconnecting
            DispatchQueue.main.async {
                guard self.session.accepts(generation) else { return }
                self.actions[target.address] = .working(disconnecting: resolved)
            }
        }
        guard session.accepts(generation) else { return }
        if isMac {
            let result = link.disconnectHost(address, cancelled: { !self.session.accepts(generation) },
                                             isConnected: { headphones.isConnected() })
            if session.accepts(generation) || !headphones.isConnected() { temporaryMac = nil }
            publishConnection(headphones, connected: headphones.isConnected(), generation: generation)
            finish(target, disconnecting: true, result: result, generation: generation)
            return
        }
        let began = Date()
        let reply = disconnecting
            ? link.request(disconnect, start, target.address, yielding: { !self.session.accepts(generation) })
            : link.request(connect, start, [0] + target.address, yielding: { !self.session.accepts(generation) })
        let result: ActionResult
        if reply?.operation == failed {
            result = .refused
        } else if reply == nil && disconnecting {
            result = .timeout
        } else {
            result = disconnecting ? .confirmed : link.waitUntilConnected(target.address, since: began,
                timeout: max(0, 20 - Date().timeIntervalSince(began)),
                cancelled: { !self.session.accepts(generation) },
                reopen: { self.openLink(headphones, generation: generation) })
        }
        // Publish and unlock before giving the Mac's temporary slot back
        finish(target, disconnecting: disconnecting, result: result, generation: generation)
    }

    private func finish(_ target: PairedDevice, disconnecting: Bool, result: ActionResult, generation: Int) {
        DispatchQueue.main.sync {
            guard self.session.accepts(generation) else { return }
            switch result {
            case .confirmed:
                self.updateState { $0.confirm(target.address, connected: !disconnecting) }
                self.actions[target.address] = .idle
            case .refused:
                self.actions[target.address] = .failed(reason: disconnecting ? "Couldn't disconnect" : "Couldn't connect")
                NSSound.beep()
            case .timeout:
                self.actions[target.address] = .failed(reason: "No answer")
            }
            self.actionPending = false
            self.clearFeedback(target.address)
            self.requestRefresh(list: self.state.devices.isEmpty)
            // Refresh after the firmware's Info lag without blocking Bluetooth
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.requestRefresh(list: self.state.devices.isEmpty)
            }
        }
    }

    private func publishCleanupFailure(_ address: [UInt8], owner: UUID?, generation: Int) {
        guard session.accepts(generation), completedActions[address] == owner, macConnected else { return }
        actions[address] = .failed(reason: "Couldn't disconnect")
        clearFeedback(address)
    }

    private func clearFeedback(_ address: [UInt8]) {
        let completion = UUID()
        completedActions[address] = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.completedActions[address] == completion { self.actions[address] = .idle }
        }
    }

    private func updateState(_ change: (inout DeviceState) -> Void) {
        var updated = state
        change(&updated)
        let fresh = Set(updated.devices.filter { updated.isFresh($0.address) }.map(\.address))
        let devicesChanged = updated.devices != state.devices
        let changed = devicesChanged || fresh != displayedFresh
        if changed { objectWillChange.send() }
        state = updated
        displayedFresh = fresh
        guard devicesChanged else { return }
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
        // Disable font smoothing for this app only
        UserDefaults.standard.set(0, forKey: "AppleFontSmoothing")
        let application = NSApplication.shared
        let delegate = App()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (delegate as? App)?.hidePanel() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           !PanelLayout.contentRect(in: frame.size).contains(event.locationInWindow) {
            (delegate as? App)?.hidePanel()
            return
        }
        super.sendEvent(event)
    }
}
