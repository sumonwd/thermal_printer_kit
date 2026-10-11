import 'printer_config.dart';

/// A printer found by `PrinterDevices`, to save in [PrinterConfig.deviceId].
class PrinterDevice {
  /// How the printer is reached.
  final PrinterConnection connection;

  /// Bluetooth address, `ble:` plus a Bluetooth LE printer's id, USB
  /// `vendorId:productId` (Android), Windows printer name (USB on Windows),
  /// driver printer URL, or IP address (network).
  final String id;

  /// The printer's name.
  final String name;

  /// Whether the device says it is a printer (Bluetooth imaging class, USB
  /// printer class, a known printer service or name). Other devices are listed
  /// too, after the printers, since many cheap printers don't say so.
  final bool isPrinter;

  /// USB vendor id (Android USB printers).
  final int? vendorId;

  /// Creates a device entry.
  const PrinterDevice({
    required this.connection,
    required this.id,
    required this.name,
    this.isPrinter = true,
    this.vendorId,
  });

  /// The printer's likely command language, from its name and vendor.
  PrinterLanguage get suggestedLanguage => suggestLanguage(name, vendorId: vendorId);

  /// A Bluetooth LE printer (found by scanning) rather than a paired Classic one.
  bool get isBle => isBleId(id);

  /// Prefix of Bluetooth LE printer ids.
  static const blePrefix = 'ble:';

  /// Whether [id] is a Bluetooth LE printer's.
  static bool isBleId(String id) => id.startsWith(blePrefix);

  /// [config] with this printer chosen and its suggested language.
  PrinterConfig applyTo(PrinterConfig config) => config.copyWith(
    connection: connection,
    deviceId: connection == PrinterConnection.network ? null : id,
    deviceName: name,
    host: connection == PrinterConnection.network ? id : null,
    language: suggestedLanguage,
  );

  @override
  String toString() => 'PrinterDevice(${connection.name}, $id, $name)';
}

/// The result of `PrinterDevices.bluetoothDevices`.
class BluetoothScan {
  /// False when Bluetooth is off or the device has none.
  final bool enabled;

  /// Printers first, then other devices, each by name.
  final List<PrinterDevice> devices;

  /// Creates a scan result.
  const BluetoothScan(this.enabled, this.devices);
}

/// Thrown when a printer can't be reached or refuses the job. [message] is
/// written to be shown to the user.
class PrinterException implements Exception {
  /// What went wrong, for the user.
  final String message;

  /// `permission` when a permission is missing, `unsupported` when the
  /// platform can't use this kind of printer, `not_ready` when no printer is
  /// chosen, else `printer`.
  final String code;

  /// Creates an exception.
  const PrinterException(this.message, {this.code = 'printer'});

  @override
  String toString() => message;
}
