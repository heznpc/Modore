import Foundation
import IOKit.ps
import Network

enum PowerSourceReader {
    static func capture(at date: Date = Date()) -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSnapshot(observedAt: date, source: .unknown, hasBattery: nil,
                                 batteryPercent: nil, isCharging: nil,
                                 lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let source: PowerSnapshot.Source
        switch providing {
        case kIOPSACPowerValue: source = .external
        case kIOPSBatteryPowerValue: source = .battery
        case kIOPMUPSPowerKey: source = .ups
        default: source = .unknown
        }
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        let battery = sources?.compactMap { value -> [String: Any]? in
            guard let description = IOPSGetPowerSourceDescription(info, value)?.takeUnretainedValue()
                as? [String: Any], description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { return nil }
            return description
        }.first
        return PowerSnapshot(
            observedAt: date, source: source, hasBattery: sources.map { _ in battery != nil },
            batteryPercent: PowerSnapshot.percentage(current: battery?[kIOPSCurrentCapacityKey] as? Int,
                                                     maximum: battery?[kIOPSMaxCapacityKey] as? Int),
            isCharging: battery?[kIOPSIsChargingKey] as? Bool,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Event-driven context shares the health watch lifetime. No additional timers,
/// network probes, shell processes, or privileged requests are needed.
@MainActor
final class PlatformContextService {
    static let shared = PlatformContextService()
    private(set) var power: PowerSnapshot?
    private(set) var connectivity: ConnectivitySnapshot?
    private var monitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var powerObserver: NSObjectProtocol?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "Modore.network-path", qos: .utility)

    func start() {
        guard monitor == nil else { return }
        let generation = UUID()
        self.generation = generation
        power = PowerSourceReader.capture()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let status: ConnectivitySnapshot.Status
            switch path.status {
            case .satisfied: status = .available
            case .requiresConnection: status = .connectionRequired
            default: status = .unavailable
            }
            let types: [(NWInterface.InterfaceType, ConnectivitySnapshot.Interface)] = [
                (.wifi, .wifi), (.wiredEthernet, .ethernet), (.cellular, .cellular),
                (.loopback, .loopback), (.other, .other)
            ]
            let snapshot = ConnectivitySnapshot(observedAt: Date(), status: status,
                interfaces: types.filter { path.usesInterfaceType($0.0) }.map(\.1),
                isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil, self.generation == generation else { return }
                self.connectivity = snapshot
            }
        }
        monitor.start(queue: queue)
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<PlatformContextService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in service.refreshPower() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPower() }
        }
    }

    private func refreshPower() {
        guard monitor != nil else { return }
        power = PowerSourceReader.capture()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        powerObserver = nil
        power = nil
        connectivity = nil
    }
}
