import 'dart:io';

import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import 'printer_config.dart';
import 'printer_device.dart';
import 'windows_raw_printer.dart';

/// Finds printers and sends them bytes:
///
/// - Bluetooth and Android USB through the plugin's native code (Android:
///   Bluetooth Classic, Bluetooth LE and USB OTG; iOS: Bluetooth LE).
/// - Windows USB printers through the print spooler (RAW jobs).
/// - Network printers over raw TCP, on every platform.
/// - Installed driver printers through the `printing` package.
class PrinterDevices {
  static const _channel = MethodChannel('thermal_printer_kit');

  /// Whether paired Classic printers are listed too (Android). Tests set it.
  final bool _listsPaired;

  /// Creates the device layer. [listsPaired] overrides whether paired
  /// Bluetooth Classic printers are listed (Android only by default).
  PrinterDevices({bool? listsPaired}) : _listsPaired = listsPaired ?? Platform.isAndroid;

  /// How long [bluetoothDevices] looks for Bluetooth LE printers.
  static const bleScanSeconds = 4;

  /// Android: paired Classic printers and Bluetooth LE ones. iOS: Bluetooth LE
  /// only (Apple doesn't let apps use Classic printers).
  static bool get supportsBluetooth => Platform.isAndroid || Platform.isIOS;

  /// Bluetooth Classic printers have to be paired in the system settings
  /// first (Android).
  static bool get bluetoothNeedsPairing => Platform.isAndroid;

  /// USB OTG (Android) or installed printers sent raw commands (Windows).
  static bool get supportsUsb => Platform.isAndroid || Platform.isWindows;

  /// Installed printers that print PDFs without a dialog.
  static bool get supportsDriver => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// The connections this platform supports, in the order to offer them.
  static List<PrinterConnection> get supportedConnections => [
    if (supportsBluetooth) PrinterConnection.bluetooth,
    if (supportsUsb) PrinterConnection.usb,
    PrinterConnection.network,
    if (supportsDriver) PrinterConnection.driver,
    PrinterConnection.system,
  ];

  /// Asks for the Bluetooth permission (Android 12+: "Nearby devices"; older
  /// Android: location, for scanning; iOS: Bluetooth). True when Bluetooth
  /// printers can be used.
  Future<bool> requestBluetoothPermission() async =>
      await _call<bool>('bluetoothPermission') ?? false;

  /// Printers paired in Android's Bluetooth settings, plus Bluetooth LE
  /// printers nearby (the only kind on iOS). A printer that is both is listed
  /// once, as Classic, which is faster. Takes [bleScanSeconds].
  Future<BluetoothScan> bluetoothDevices() async {
    if (!await requestBluetoothPermission()) {
      throw PrinterException(
        Platform.isIOS
            ? 'Allow Bluetooth for this app in Settings to use Bluetooth printers.'
            : 'Allow "Nearby devices" for this app to use Bluetooth printers.',
        code: 'permission',
      );
    }
    final paired = _listsPaired ? await _call<Map>('bluetoothDevices') ?? const {} : const {};
    final scan = await _call<Map>('bleScan', {'seconds': bleScanSeconds}) ?? const {};

    final devices = <PrinterDevice>[
      for (final d in (paired['devices'] as List?) ?? const [])
        if (d is Map)
          PrinterDevice(
            connection: PrinterConnection.bluetooth,
            id: d['address'].toString(),
            name: (d['name'] ?? d['address']).toString(),
            isPrinter: d['isPrinter'] == true,
          ),
    ];
    final classic = devices.map((d) => d.id).toSet();
    for (final d in (scan['devices'] as List?) ?? const []) {
      if (d is! Map || classic.contains(d['id'])) continue;
      devices.add(
        PrinterDevice(
          connection: PrinterConnection.bluetooth,
          id: '${PrinterDevice.blePrefix}${d['id']}',
          name: (d['name'] ?? 'Bluetooth printer').toString(),
          isPrinter: d['isPrinter'] == true,
        ),
      );
    }
    devices.sort(
      (a, b) => (a.isPrinter == b.isPrinter) ? a.name.compareTo(b.name) : (a.isPrinter ? -1 : 1),
    );
    return BluetoothScan(paired['enabled'] == true || scan['enabled'] == true, devices);
  }

  /// Opens the system Bluetooth settings (Android) or this app's page in
  /// Settings (iOS), to pair a printer or allow Bluetooth.
  Future<void> openBluetoothSettings() => _call('openBluetoothSettings');

  /// USB OTG devices with a printer-like endpoint (Android), or installed
  /// printers (Windows), which are sent raw commands.
  Future<List<PrinterDevice>> usbDevices() async {
    if (Platform.isWindows) {
      final printers = await Printing.listPrinters();
      return [
        for (final p in printers)
          if (p.isAvailable)
            PrinterDevice(connection: PrinterConnection.usb, id: p.name, name: p.name),
      ];
    }
    final list = await _call<List>('usbDevices') ?? const [];
    return [
      for (final d in list)
        if (d is Map)
          PrinterDevice(
            connection: PrinterConnection.usb,
            id: '${d['vendorId']}:${d['productId']}',
            name: (d['name'] ?? 'USB printer').toString(),
            isPrinter: d['isPrinter'] == true,
            vendorId: d['vendorId'] as int?,
          ),
    ];
  }

  /// Installed printers (Windows, macOS, Linux) that print PDFs without a
  /// dialog.
  Future<List<PrinterDevice>> driverPrinters() async => [
    for (final p in await Printing.listPrinters())
      if (p.isAvailable)
        PrinterDevice(connection: PrinterConnection.driver, id: p.url, name: p.name),
  ];

  /// Looks for printers listening on [port] on this device's private IPv4
  /// networks (each /24 the device is on), [batchSize] addresses at a time.
  /// Emits each printer's address as it is found.
  Stream<PrinterDevice> scanNetwork({
    int port = 9100,
    Duration timeout = const Duration(milliseconds: 500),
    int batchSize = 64,
  }) async* {
    final own = <String>{};
    final subnets = <String>{};
    for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final addr in iface.addresses) {
        final parts = addr.address.split('.');
        if (parts.length != 4 || addr.isLoopback || !_isPrivate(parts)) continue;
        own.add(addr.address);
        subnets.add(parts.take(3).join('.'));
      }
    }
    final targets = [
      for (final subnet in subnets)
        for (var i = 1; i < 255; i++)
          if (!own.contains('$subnet.$i')) '$subnet.$i',
    ];
    // In batches, so a /24 takes a couple of seconds without opening 254 sockets at once
    for (var i = 0; i < targets.length; i += batchSize) {
      final found = await Future.wait(
        targets.skip(i).take(batchSize).map((ip) async {
          try {
            final socket = await Socket.connect(ip, port, timeout: timeout);
            socket.destroy();
            return ip;
          } catch (_) {
            return null;
          }
        }),
      );
      for (final ip in found.nonNulls) {
        yield PrinterDevice(connection: PrinterConnection.network, id: ip, name: '$ip:$port');
      }
    }
  }

  static bool _isPrivate(List<String> p) {
    final a = int.tryParse(p[0]) ?? 0;
    final b = int.tryParse(p[1]) ?? 0;
    return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
  }

  /// Sends to a paired Classic printer (its address) or a Bluetooth LE one
  /// (`ble:` id).
  Future<void> sendBluetooth(String id, Uint8List bytes) => PrinterDevice.isBleId(id)
      ? _call('bleSend', {'id': id.substring(PrinterDevice.blePrefix.length), 'bytes': bytes})
      : _call('bluetoothSend', {'address': id, 'bytes': bytes});

  /// Sends to a USB OTG printer (`vendorId:productId`, Android) or an
  /// installed printer by name (Windows, as a RAW job named [documentName]).
  Future<void> sendUsb(String id, Uint8List bytes, {String documentName = 'Receipt'}) async {
    if (Platform.isWindows) {
      return WindowsRawPrinter.send(id, bytes, documentName: documentName);
    }
    final parts = id.split(':');
    await _call('usbSend', {
      'vendorId': int.tryParse(parts.first) ?? 0,
      'productId': int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
      'bytes': bytes,
    });
  }

  /// Raw TCP, as LAN/Wi-Fi thermal printers expect on port 9100.
  Future<void> sendNetwork(String host, int port, Uint8List bytes) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      socket.add(bytes);
      await socket.flush().timeout(const Duration(seconds: 20));
    } on SocketException catch (e) {
      throw PrinterException(
        'Could not reach the printer at $host:$port (${e.osError?.message ?? e.message}).',
      );
    } on Exception {
      throw PrinterException('The printer at $host:$port did not respond.');
    } finally {
      await socket?.close().timeout(const Duration(seconds: 5), onTimeout: () => socket?.destroy());
    }
  }

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw PrinterException(e.message ?? 'The printer could not be reached.', code: e.code);
    } on MissingPluginException {
      throw const PrinterException(
        'This printer type is not supported on this device.',
        code: 'unsupported',
      );
    }
  }
}
