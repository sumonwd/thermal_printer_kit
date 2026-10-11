import CoreBluetooth
import Flutter
import UIKit

/// Receipt printers over Bluetooth Low Energy, for ThermalPrinterKitPlugin
/// (the Android side is PrinterDevices.kt and BlePrinters.kt).
///
/// iOS doesn't let apps use Bluetooth Classic (SPP) printers, only BLE ones
/// (and MFi accessories). The app sends ready-made printer commands (ESC/POS or
/// Star), so this only finds printers and moves bytes: it writes them to the
/// printer's writable characteristic in chunks the link can take.
final class BlePrinters: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  /// Service / characteristic pairs used by common BLE receipt printers, tried
  /// before any other writable characteristic.
  private static let knownCharacteristics: [(service: CBUUID, characteristic: CBUUID)] = [
    (CBUUID(string: "18F0"), CBUUID(string: "2AF1")),
    (CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"), CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F")),
    (CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"), CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")),
    (CBUUID(string: "FF00"), CBUUID(string: "FF02")),
    (CBUUID(string: "FFE0"), CBUUID(string: "FFE1")),
  ]

  /// Standard services that never take print data.
  private static let ignoredServices: Set<CBUUID> = [
    CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A"), CBUUID(string: "180F"),
  ]

  private let queue = DispatchQueue(label: "thermal_printer_kit.ble")
  private lazy var central = CBCentralManager(delegate: self, queue: queue)

  // State of the one job in progress (all touched on `queue` only)
  private var stateWaiters: [(CBManagerState) -> Void] = []
  private var found: [UUID: (peripheral: CBPeripheral, name: String, isPrinter: Bool)] = [:]
  private var lookingFor: UUID?
  private var lookupDone: ((CBPeripheral?) -> Void)?
  private var job: SendJob?

  private final class SendJob {
    let peripheral: CBPeripheral
    let data: Data
    let done: (String?) -> Void
    var characteristic: CBCharacteristic?
    var withResponse = false
    var offset = 0
    var chunk = 20
    var servicesLeft = 0
    var timeout: DispatchWorkItem?

    init(peripheral: CBPeripheral, data: Data, done: @escaping (String?) -> Void) {
      self.peripheral = peripheral
      self.data = data
      self.done = done
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    switch call.method {
    case "bluetoothPermission":
      queue.async { self.whenReady { state in reply(state != .unauthorized) } }
    case "bleScan":
      let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? 4
      queue.async { self.scan(seconds: seconds, reply: reply) }
    case "bleSend":
      guard let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)),
            let bytes = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "printer", message: "No Bluetooth printer chosen.", details: nil))
        return
      }
      queue.async {
        self.send(to: id, data: bytes.data) { error in
          reply(error.map { FlutterError(code: "printer", message: $0, details: nil) })
        }
      }
    case "openBluetoothSettings":
      // Apps can only open their own page in Settings (where Bluetooth access is allowed)
      DispatchQueue.main.async {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Bluetooth state

  /// Runs [then] once Bluetooth has settled (the first access shows the permission prompt).
  private func whenReady(_ then: @escaping (CBManagerState) -> Void) {
    let state = central.state
    if state != .unknown && state != .resetting {
      then(state)
      return
    }
    stateWaiters.append(then)
    queue.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self, !self.stateWaiters.isEmpty else { return }
      let waiters = self.stateWaiters
      self.stateWaiters = []
      waiters.forEach { $0(self.central.state) }
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state != .unknown && central.state != .resetting {
      let waiters = stateWaiters
      stateWaiters = []
      waiters.forEach { $0(central.state) }
    }
    if central.state != .poweredOn, let job {
      finish(job, error: "Bluetooth was turned off.")
    }
  }

  private static func problem(_ state: CBManagerState) -> String? {
    switch state {
    case .poweredOn: return nil
    case .unauthorized: return "Allow Bluetooth for this app in Settings to use Bluetooth printers."
    case .unsupported: return "This device has no Bluetooth LE."
    default: return "Bluetooth is off. Turn it on to print."
    }
  }

  // MARK: - Finding printers

  private func scan(seconds: Double, reply: @escaping (Any?) -> Void) {
    whenReady { state in
      if state == .unauthorized {
        reply(FlutterError(code: "permission", message: Self.problem(state), details: nil))
        return
      }
      guard state == .poweredOn else {
        reply(["enabled": false, "devices": []])
        return
      }
      if self.job == nil {
        self.found = [:]
        self.central.scanForPeripherals(withServices: nil, options: nil)
      }
      self.queue.asyncAfter(deadline: .now() + seconds) {
        if self.job == nil && self.lookingFor == nil { self.central.stopScan() }
        // Printers already connected to this device don't advertise
        let connected = self.central.retrieveConnectedPeripherals(withServices: Self.knownCharacteristics.map(\.service))
        for p in connected where self.found[p.identifier] == nil {
          self.found[p.identifier] = (p, p.name ?? "Bluetooth printer", true)
        }
        let devices = self.found.values.map { entry -> [String: Any] in
          ["id": entry.peripheral.identifier.uuidString, "name": entry.name, "isPrinter": entry.isPrinter]
        }
        reply(["enabled": true, "devices": devices])
      }
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    if peripheral.identifier == lookingFor {
      lookingFor = nil
      central.stopScan()
      let done = lookupDone
      lookupDone = nil
      done?(peripheral)
      return
    }
    // Unnamed devices (beacons, phones, ...) can't be told apart, so leave them out
    guard let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name,
          !name.isEmpty else { return }
    let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let known = Set(Self.knownCharacteristics.map(\.service))
    let printerName = ["print", "pos", "tsp", "star", "mpt", "rpp", "xp-", "mtp", "bt-", "pt-"]
      .contains { name.lowercased().contains($0) }
    found[peripheral.identifier] = (peripheral, name, printerName || services.contains { known.contains($0) })
  }

  /// The peripheral for a saved id: known to iOS from an earlier scan, or found by scanning again.
  private func peripheral(for id: UUID, then: @escaping (CBPeripheral?) -> Void) {
    if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
      then(p)
      return
    }
    lookingFor = id
    lookupDone = then
    central.scanForPeripherals(withServices: nil, options: nil)
    queue.asyncAfter(deadline: .now() + 6) { [weak self] in
      guard let self, self.lookingFor == id else { return }
      self.lookingFor = nil
      self.central.stopScan()
      let done = self.lookupDone
      self.lookupDone = nil
      done?(nil)
    }
  }

  // MARK: - Sending

  private func send(to id: UUID, data: Data, done: @escaping (String?) -> Void) {
    whenReady { state in
      if let problem = Self.problem(state) {
        done(problem)
        return
      }
      guard self.job == nil else {
        done("The printer is still busy with the last receipt.")
        return
      }
      self.peripheral(for: id) { peripheral in
        guard let peripheral else {
          done("The Bluetooth printer was not found. Is it on and nearby?")
          return
        }
        let job = SendJob(peripheral: peripheral, data: data, done: done)
        self.job = job
        let timeout = DispatchWorkItem { [weak self] in
          guard let self, self.job === job else { return }
          self.finish(job, error: job.characteristic == nil
            ? "Could not connect to \(peripheral.name ?? "the printer"). Is it on and nearby?"
            : "The printer stopped responding.")
        }
        job.timeout = timeout
        // Long enough for a big receipt over a slow link
        self.queue.asyncAfter(deadline: .now() + 60, execute: timeout)
        peripheral.delegate = self
        self.central.connect(peripheral, options: nil)
      }
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let job, job.peripheral === peripheral else { return }
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard let job, job.peripheral === peripheral else { return }
    finish(job, error: "Could not connect to \(peripheral.name ?? "the printer"). Is it on and nearby?")
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    guard let job, job.peripheral === peripheral else { return }
    finish(job, error: job.offset >= job.data.count ? nil : "The printer disconnected before the receipt was sent.")
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let job, job.peripheral === peripheral else { return }
    let services = (peripheral.services ?? []).filter { !Self.ignoredServices.contains($0.uuid) }
    guard error == nil, !services.isEmpty else {
      finish(job, error: "This Bluetooth device can't take print jobs.")
      return
    }
    job.servicesLeft = services.count
    services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let job, job.peripheral === peripheral, job.characteristic == nil else { return }
    job.servicesLeft -= 1
    guard job.servicesLeft <= 0 else { return }

    let characteristics = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
    let writable = characteristics.filter { !$0.properties.isDisjoint(with: [.write, .writeWithoutResponse]) }
    let known = Self.knownCharacteristics.lazy.compactMap { pair in
      writable.first { $0.uuid == pair.characteristic && $0.service?.uuid == pair.service }
    }.first
    guard let characteristic = known ?? writable.first else {
      finish(job, error: "This Bluetooth device can't take print jobs.")
      return
    }
    job.characteristic = characteristic
    // Without a response is much faster; iOS paces it (canSendWriteWithoutResponse)
    job.withResponse = !characteristic.properties.contains(.writeWithoutResponse)
    job.chunk = max(20, min(512, peripheral.maximumWriteValueLength(for: job.withResponse ? .withResponse : .withoutResponse)))
    pump(job)
  }

  /// Writes the next chunks: one at a time with a response, else as fast as the link allows.
  private func pump(_ job: SendJob) {
    guard let characteristic = job.characteristic else { return }
    while job.offset < job.data.count {
      if !job.withResponse && !job.peripheral.canSendWriteWithoutResponse { return }  // peripheralIsReady resumes
      let end = min(job.offset + job.chunk, job.data.count)
      let chunk = job.data.subdata(in: job.offset..<end)
      job.offset = end
      job.peripheral.writeValue(chunk, for: characteristic, type: job.withResponse ? .withResponse : .withoutResponse)
      if job.withResponse { return }  // didWriteValueFor resumes
    }
    // All handed over: give the radio a moment to deliver the last chunks, then hang up
    queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self.job === job else { return }
      self.finish(job, error: nil)
    }
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard let job, job.peripheral === peripheral, !job.withResponse else { return }
    pump(job)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let job, job.peripheral === peripheral, job.withResponse else { return }
    if let error {
      finish(job, error: "The printer refused the data: \(error.localizedDescription)")
      return
    }
    pump(job)
  }

  private func finish(_ job: SendJob, error: String?) {
    guard self.job === job else { return }
    self.job = nil
    job.timeout?.cancel()
    central.cancelPeripheralConnection(job.peripheral)
    job.done(error)
  }
}
