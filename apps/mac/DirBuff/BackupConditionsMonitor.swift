import AppKit
import DirBuffCore
import IOKit.ps
import Network

/// Watches what holds Backup's owed runs: the network, Low Power Mode and the battery. Tells its
/// owner on the main actor whenever the picture changes.
@MainActor
final class BackupConditionsMonitor {
  private(set) var conditions: BackupConditions
  private let onChange: @MainActor (BackupConditions) -> Void
  private let pathMonitor = NWPathMonitor()
  private var powerSource: CFRunLoopSource?
  private var lowPowerObserver: (any NSObjectProtocol)?

  init(onChange: @escaping @MainActor (BackupConditions) -> Void) {
    self.onChange = onChange
    // Offline until the first path arrives, so nothing starts on a guess.
    conditions = BackupConditions(
      network: .offline, isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      power: Self.power())
  }

  func start() {
    pathMonitor.pathUpdateHandler = { path in
      let network = Self.network(path)
      Task { @MainActor in self.update { $0.network = network } }
    }
    pathMonitor.start(queue: DispatchQueue(label: "app.fishball.dirbuff.network", qos: .utility))

    lowPowerObserver = NotificationCenter.default.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in
        self.update { $0.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
      }
    }

    // The monitor lives as long as the app, so the run loop source holds it unretained.
    let context = Unmanaged.passUnretained(self).toOpaque()
    if let source = IOPSNotificationCreateRunLoopSource(
      { context in
        guard let context else { return }
        let monitor = Unmanaged<BackupConditionsMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.update { $0.power = BackupConditionsMonitor.power() } }
      }, context)?.takeRetainedValue()
    {
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
      powerSource = source
    }
  }

  private func update(_ change: (inout BackupConditions) -> Void) {
    var updated = conditions
    change(&updated)
    guard updated != conditions else { return }
    conditions = updated
    onChange(updated)
  }

  nonisolated private static func network(_ path: NWPath) -> BackupNetwork {
    guard path.status == .satisfied else { return .offline }
    return path.isExpensive || path.isConstrained ? .expensive : .unmetered
  }

  /// On mains unless the Mac runs on its internal battery, and then its charge.
  nonisolated private static func power() -> BackupPower {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
      let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?,
      providing == kIOPSBatteryPowerValue
    else { return .mains }
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let current = description[kIOPSCurrentCapacityKey] as? Int,
        let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
      else { continue }
      return .battery(percent: current * 100 / maximum)
    }
    return .mains
  }
}
