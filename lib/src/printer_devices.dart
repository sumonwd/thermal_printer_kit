import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import 'printer_config.dart';
import 'printer_device.dart';
import 'snmp.dart';
import 'windows_raw_printer.dart';
import 'windows_usb_printer.dart';

/// Finds printers and sends them bytes:
///
/// - Bluetooth and Android USB through the plugin's native code (Android:
///   Bluetooth Classic, Bluetooth LE and USB OTG; iOS: Bluetooth LE).
/// - Windows USB printers directly by their device path, or through the
///   print spooler (RAW jobs) when they are installed.
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

  /// USB OTG (Android), or USB and installed printers sent raw commands
  /// (Windows).
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

  /// USB OTG devices with a printer-like endpoint (Android). On Windows,
  /// installed printers, which are sent raw commands through the spooler, then
  /// the printers plugged in by USB, which are sent them directly and need no
  /// driver. A USB printer that is also installed is listed both ways.
  Future<List<PrinterDevice>> usbDevices() async {
    if (Platform.isWindows) {
      final printers = await Printing.listPrinters();
      return [
        for (final p in printers)
          if (p.isAvailable)
            PrinterDevice(connection: PrinterConnection.usb, id: p.name, name: p.name),
        for (final path in WindowsUsbPrinter.devicePaths())
          PrinterDevice(
            connection: PrinterConnection.usb,
            id: path,
            name: WindowsUsbPrinter.nameOf(path),
            vendorId: WindowsUsbPrinter.vendorIdOf(path),
          ),
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
  /// Emits each printer as it is found, named by [networkName], or by its
  /// address and port when it doesn't give a name.
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
      final named = await Future.wait(
        found.nonNulls.map((ip) async => (ip, await networkName(ip, port: port))),
      );
      for (final (ip, name) in named) {
        yield PrinterDevice(
          connection: PrinterConnection.network,
          id: ip,
          name: name ?? '$ip:$port',
        );
      }
    }
  }

  /// A network printer's name, asked without printing anything:
  ///
  /// 1. Star discovery (UDP 22222): Star LAN printers give their model.
  /// 2. SNMP (UDP 161, community `public`): the model, host name or
  ///    description, as Epson TM, office and many other printers give.
  /// 3. With [askEscPos], when neither answers: the ESC/POS printer ID
  ///    command (GS I) on [port], which gives the maker and model of most
  ///    LAN receipt printers. Star and SNMP printers are never sent it, as an
  ///    office printer could print it as text.
  ///
  /// Each step waits up to [timeout]. Null when nothing answers.
  Future<String?> networkName(
    String host, {
    int port = 9100,
    bool askEscPos = true,
    Duration timeout = const Duration(milliseconds: 800),
    @visibleForTesting int snmpPort = 161,
    @visibleForTesting int starPort = 22222,
  }) async {
    final InternetAddress address;
    try {
      address = (await InternetAddress.lookup(host)).first;
    } on Exception {
      return null;
    }
    final (star, snmp) = await (
      _starName(address, starPort, timeout),
      _snmpName(address, snmpPort, timeout),
    ).wait;
    if (star != null || snmp != null || !askEscPos) return star ?? snmp;
    return _escPosName(address, port, timeout);
  }

  // Star discovery request, as Star's own utilities send it
  static final _starRequest = [
    ...'STR_BCAST'.codeUnits,
    0, 0, 0, 0, 0, 0, 0, //
    ...'RQ1.0.0'.codeUnits,
    0, 0, 0x1C, 0x64, 0x31,
  ];

  static Future<String?> _starName(InternetAddress address, int port, Duration timeout) async {
    String? name;
    await _askUdp(address, port, [_starRequest], timeout, (reply) {
      if (reply.length < 9 || String.fromCharCodes(reply.take(9)) != 'STR_BCAST') return false;
      // The model is the text with the emulation after it: "TSP143IIILAN (STR_T-001)"
      for (final text in RegExp(r'[\x20-\x7E]{4,}').allMatches(String.fromCharCodes(reply))) {
        final model = RegExp(r'^(\S.*?) \(.+\)$').firstMatch(text[0]!)?[1];
        if (model != null) {
          name = model.toLowerCase().startsWith('star') ? model : 'Star $model';
          return true;
        }
      }
      return false;
    });
    return name;
  }

  // hrDeviceDescr.1 (model), sysName.0, sysDescr.0: the first that answers
  static const _nameOids = ['1.3.6.1.2.1.25.3.2.1.3.1', '1.3.6.1.2.1.1.5.0', '1.3.6.1.2.1.1.1.0'];

  static Future<String?> _snmpName(InternetAddress address, int port, Duration timeout) async {
    final answers = <int, String?>{};
    await _askUdp(
      address,
      port,
      [for (var i = 0; i < _nameOids.length; i++) Snmp.getRequest(_nameOids[i], i + 1)],
      timeout,
      (reply) {
        final response = Snmp.parseResponse(reply);
        if (response != null) answers[response.$1] = response.$2;
        return answers.length == _nameOids.length;
      },
    );
    for (var i = 1; i <= _nameOids.length; i++) {
      final name = _cleanName(answers[i]);
      if (name != null) return name;
    }
    return null;
  }

  /// GS I 67 (model name), then GS I 66 (maker): each answered `_` text NUL.
  static Future<String?> _escPosName(InternetAddress address, int port, Duration timeout) async {
    Socket? socket;
    try {
      socket = await Socket.connect(address, port, timeout: timeout);
      final received = <int>[];
      var arrived = Completer<void>();
      socket.listen(
        (data) {
          received.addAll(data);
          if (!arrived.isCompleted) arrived.complete();
        },
        onError: (_) {},
        cancelOnError: true,
      );
      Future<String?> ask(int n) async {
        received.clear();
        socket!.add([0x1D, 0x49, n]);
        final deadline = DateTime.now().add(timeout);
        while (true) {
          final start = received.indexOf(0x5F);
          final end = start < 0 ? -1 : received.indexOf(0x00, start);
          if (end > 0) return _cleanName(String.fromCharCodes(received, start + 1, end));
          final left = deadline.difference(DateTime.now());
          if (left <= Duration.zero) return null;
          arrived = Completer<void>();
          await arrived.future.timeout(left, onTimeout: () {});
        }
      }

      final model = await ask(0x43);
      if (model == null) return null;
      final maker = await ask(0x42);
      return maker == null || model.toLowerCase().startsWith(maker.toLowerCase())
          ? model
          : '$maker $model';
    } on Exception {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  /// Sends [requests] over UDP and hands each reply to [onReply] until it
  /// returns true or [timeout] passes.
  static Future<void> _askUdp(
    InternetAddress address,
    int port,
    List<List<int>> requests,
    Duration timeout,
    bool Function(Uint8List reply) onReply,
  ) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        address.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0,
      );
      final done = Completer<void>();
      socket.listen((event) {
        final packet = event == RawSocketEvent.read ? socket?.receive() : null;
        if (packet != null && onReply(packet.data) && !done.isCompleted) done.complete();
      }, onError: (_) {});
      for (final request in requests) {
        socket.send(request, address, port);
      }
      await done.future.timeout(timeout, onTimeout: () {});
    } on Exception {
      // No answer
    } finally {
      socket?.close();
    }
  }

  /// The first line of [text], trimmed and at most 64 characters, or null.
  static String? _cleanName(String? text) {
    final name = text?.split(RegExp(r'[\r\n\x00]')).first.trim() ?? '';
    if (name.isEmpty) return null;
    return name.length > 64 ? name.substring(0, 64) : name;
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

  /// Sends to a USB OTG printer (`vendorId:productId`, Android). On Windows,
  /// to a USB printer by its device path, or to an installed printer by name
  /// (as a RAW job named [documentName]).
  Future<void> sendUsb(String id, Uint8List bytes, {String documentName = 'Receipt'}) async {
    if (Platform.isWindows) {
      if (WindowsUsbPrinter.isDevicePath(id)) return WindowsUsbPrinter.send(id, bytes);
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
