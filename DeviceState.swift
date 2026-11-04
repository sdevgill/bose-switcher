import Foundation

struct PairedDevice: Codable, Identifiable, Equatable {
    let address: [UInt8]
    let name: String
    var connected = false
    var active = false
    var id: [UInt8] { address }

    var displayName: String {
        if let prefix = name.range(of: "’s ") ?? name.range(of: "'s ") {
            return String(name[prefix.upperBound...])
        }
        return name
    }

    var symbol: String {
        if name.localizedCaseInsensitiveContains("iPhone") { return "iphone" }
        if name.localizedCaseInsensitiveContains("Mac") { return "laptopcomputer" }
        if name.localizedCaseInsensitiveContains("TV") { return "appletv" }
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
    case confirmed

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
    func isFresh(_ address: [UInt8]) -> Bool { fresh.contains(address) }

    mutating func invalidateReadings() { fresh.removeAll() }

    // Missing answers leave the current device alone, including its confirmed state
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
    mutating func confirm(_ address: [UInt8], connected: Bool, at date: Date = Date()) {
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
