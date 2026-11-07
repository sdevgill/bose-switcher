import Foundation

struct PairedDevice: Codable, Identifiable, Equatable {
    let address: [UInt8]
    let name: String
    var connected = false
    var active = false
    var id: [UInt8] { address }

    var displayName: String {
        if let prefix = name.range(of: "’s ") ?? name.range(of: "'s ") {
            let shortened = String(name[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !shortened.isEmpty { return shortened }
        }
        return name
    }

    // A damaged cache must not reach the packet writer, so keep unique six-byte addresses only
    static func cached(_ data: Data) -> [PairedDevice] {
        let saved = (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
        var seen = Set<[UInt8]>()
        return saved.filter { $0.address.count == 6 && seen.insert($0.address).inserted }
    }

    // Guess the device type from its Bluetooth name, falling back to a desktop
    var symbol: String {
        func has(_ words: String...) -> Bool { words.contains { name.localizedCaseInsensitiveContains($0) } }
        if has("iPad", "Galaxy Tab", "Tablet") { return "ipad" }
        if has("Phone", "Pixel", "Galaxy", "OnePlus", "Xperia") { return "iphone" }
        if has("iMac", "Mac mini", "Mac Studio", "Mac Pro", "Desktop") { return "pc" }
        if has("Mac", "Laptop", "ThinkPad", "Surface") { return "laptopcomputer" }
        if has("TV") { return "appletv" }
        return "pc"
    }
}

enum ActionResult {
    case confirmed, refused, timeout
}

enum RowAction: Equatable {
    case idle
    case checking
    case working(disconnecting: Bool)
    case failed(reason: String)

    var working: Bool {
        if case .checking = self { return true }
        if case .working = self { return true }
        return false
    }
}

struct DeviceState {
    var devices: [PairedDevice] = []
    private var updatedAt: [[UInt8]: Date] = [:]
    private var protectedUntil: [[UInt8]: Date] = [:]
    private var confirmedConnections: [[UInt8]: Bool] = [:]
    private var order: [[UInt8]] = []
    private var membershipKnown = false
    private var fresh: Set<[UInt8]> = []

    var knownAddresses: [[UInt8]] { membershipKnown ? order : devices.map(\.address) }
    func isFresh(_ address: [UInt8], since began: Date = .distantPast, at date: Date = monotonicNow()) -> Bool {
        let requestedAt = updatedAt[address] ?? .distantPast
        return fresh.contains(address) && requestedAt >= began && date.timeIntervalSince(requestedAt) < 5
    }

    func displayName(for device: PairedDevice) -> String {
        devices.contains { $0.address != device.address && $0.displayName == device.displayName }
            ? device.name : device.displayName
    }

    mutating func invalidateReadings() {
        fresh.removeAll()
        protectedUntil.removeAll()
        confirmedConnections.removeAll()
    }

    mutating func reconcileOrder(_ addresses: [[UInt8]], computer: [UInt8]) {
        let previous = knownAddresses.filter { addresses.contains($0) }
        let stable = previous + addresses.filter { !previous.contains($0) }
        reorder(stable.filter { $0 == computer } + stable.filter { $0 != computer })
    }

    // Update only devices that answered and preserve recent confirmations
    mutating func merge(_ reading: DeviceReading) {
        let address = reading.device.address
        guard !membershipKnown || order.contains(address) else { return }
        guard reading.requestedAt >= (updatedAt[address] ?? .distantPast) else { return }
        var device = reading.device
        if reading.requestedAt < (protectedUntil[address] ?? .distantPast),
           let connected = confirmedConnections[address], connected != device.connected {
            device.connected = connected
            device.active = connected && (devices.first { $0.address == address }?.active ?? false)
        }
        if let index = devices.firstIndex(where: { $0.address == address }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        updatedAt[address] = reading.requestedAt
        fresh.insert(address)
        sort()
    }

    // Info can lag a command by two seconds, even when requested after confirmation
    mutating func confirm(_ address: [UInt8], connected: Bool, at date: Date = monotonicNow()) {
        if let index = devices.firstIndex(where: { $0.address == address }) {
            devices[index].connected = connected
            if !connected || !fresh.contains(address) { devices[index].active = false }
        }
        updatedAt[address] = date
        protectedUntil[address] = date.addingTimeInterval(2.5)
        confirmedConnections[address] = connected
        fresh.insert(address)
    }

    mutating func reorder(_ addresses: [[UInt8]]) {
        order = addresses
        membershipKnown = true
        devices.removeAll { !addresses.contains($0.address) }
        updatedAt = updatedAt.filter { addresses.contains($0.key) }
        protectedUntil = protectedUntil.filter { addresses.contains($0.key) }
        confirmedConnections = confirmedConnections.filter { addresses.contains($0.key) }
        fresh.formIntersection(addresses)
        sort()
    }

    private mutating func sort() {
        let previous = devices.map(\.address)
        devices.sort {
            (order.firstIndex(of: $0.address) ?? order.count + (previous.firstIndex(of: $0.address) ?? 0)) <
            (order.firstIndex(of: $1.address) ?? order.count + (previous.firstIndex(of: $1.address) ?? 0))
        }
    }
}

// Cancel queued work across power and sleep changes
final class WorkSession {
    private let lock = NSLock()
    private var generation = 0
    private var available = false

    var current: Int { lock.withLock { generation } }

    func begin(available: Bool) {
        lock.withLock { generation += 1; self.available = available }
    }

    func accepts(_ generation: Int) -> Bool {
        lock.withLock { available && self.generation == generation }
    }
}
