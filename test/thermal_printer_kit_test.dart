import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:thermal_printer_kit/src/snmp.dart';
import 'package:thermal_printer_kit/thermal_printer_kit.dart';

/// A 16 x 3 image: row 0 all black, row 1 only the first dot, row 2 blank.
MonoImage sampleImage() =>
    MonoImage(16, 3, Uint8List.fromList([0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00]));

/// Index of [pattern] in [bytes], or -1.
int indexOf(List<int> bytes, List<int> pattern, [int start = 0]) {
  for (var i = start; i <= bytes.length - pattern.length; i++) {
    var match = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

/// An SNMP v1 GetResponse to request [id]: [value] as text, or a noSuchName
/// error when it is null.
List<int> snmpResponse(int id, String? value) {
  List<int> tlv(int tag, List<int> v) => [tag, v.length, ...v];
  return tlv(0x30, [
    ...tlv(0x02, [0]),
    ...tlv(0x04, 'public'.codeUnits),
    ...tlv(0xA2, [
      ...tlv(0x02, [id]),
      ...tlv(0x02, [value == null ? 2 : 0]),
      ...tlv(0x02, [value == null ? 1 : 0]),
      ...tlv(
        0x30,
        tlv(0x30, [
          ...tlv(0x06, [0x2B, 6, 1, 2, 1, 1, 5, 0]),
          ...(value == null ? [0x05, 0x00] : tlv(0x04, value.codeUnits)),
        ]),
      ),
    ]),
  ]);
}

int count(List<int> bytes, List<int> pattern) {
  var n = 0;
  for (var i = indexOf(bytes, pattern); i >= 0; i = indexOf(bytes, pattern, i + 1)) {
    n++;
  }
  return n;
}

/// A local TCP "printer"; [received] completes with everything sent to it.
Future<({int port, Future<List<int>> received})> fakeNetworkPrinter() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final received = server.first.then(
    (client) => client.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
  );
  return (port: server.port, received: received);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Printer commands', () {
    test('ESC/POS: raster strips, drawer once, a cut per copy', () {
      final bytes = PrinterCommands.receipt(
        sampleImage(),
        PrinterLanguage.escPos,
        copies: 2,
        openDrawer: true,
      );

      // ESC @, then GS L 0 (no left margin) and GS W 16 (print area as wide as the image)
      expect(bytes.sublist(0, 10), [0x1B, 0x40, 0x1D, 0x4C, 0, 0, 0x1D, 0x57, 16, 0]);
      expect(count(bytes, [0x1B, 0x70, 0x00, 0x19, 0xFA]), 1);
      // GS v 0, 2 bytes wide, 3 rows high, then the data
      final image = indexOf(bytes, [0x1D, 0x76, 0x30, 0x00, 2, 0, 3, 0]);
      expect(image, greaterThan(0));
      expect(bytes.sublist(image + 8, image + 14), [0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00]);
      expect(count(bytes, [0x1D, 0x56, 0x42, 0x00]), 2);
    });

    test('ESC/POS: tall images are split into strips', () {
      final tall = MonoImage(8, 300, Uint8List(300)..fillRange(0, 300, 0xFF));
      final bytes = PrinterCommands.receipt(tall, PrinterLanguage.escPos);
      expect(indexOf(bytes, [0x1D, 0x76, 0x30, 0x00, 1, 0, 128, 0]), greaterThan(0));
      expect(indexOf(bytes, [0x1D, 0x76, 0x30, 0x00, 1, 0, 44, 0]), greaterThan(0));
      expect(count(bytes, [0x1D, 0x76, 0x30, 0x00]), 3);
    });

    test('Star Line: raster mode, trimmed rows, drawer before the image, EOT cut', () {
      final bytes = PrinterCommands.receipt(
        sampleImage(),
        PrinterLanguage.starLine,
        openDrawer: true,
      );

      expect(bytes.sublist(0, 8), [0x1B, 0x2A, 0x72, 0x52, 0x1B, 0x2A, 0x72, 0x41]);
      // Continuous paper and feed-to-cutter + partial cut, whatever the memory switches say
      expect(bytes.sublist(8, 21), [
        0x1B, 0x2A, 0x72, 0x50, 0x30, 0x00, 0x1B, 0x2A, 0x72, 0x45, 0x31, 0x33, 0x00, //
      ]);
      final drawer = indexOf(bytes, [0x1B, 0x2A, 0x72, 0x44, 0x31, 0x00]);
      final firstRow = indexOf(bytes, [0x62, 2, 0, 0xFF, 0xFF]);
      expect(drawer, greaterThan(0));
      expect(firstRow, greaterThan(drawer));
      // Trailing white bytes are dropped; a blank row still sends one byte
      expect(indexOf(bytes, [0x62, 1, 0, 0x80, 0x62, 1, 0, 0x00]), greaterThan(firstRow));
      expect(bytes.sublist(bytes.length - 7), [0x1B, 0x0C, 0x04, 0x1B, 0x2A, 0x72, 0x42]);
    });

    test('extra feed before the cut, in each printer language', () {
      final image = sampleImage();
      final escPos = PrinterCommands.receipt(image, PrinterLanguage.escPos, extraFeedMm: 40);
      // 40 mm = 320 dot rows, as ESC J 255 + ESC J 65, then the usual feed and cut
      final feed = indexOf(escPos, [0x1B, 0x4A, 255, 0x1B, 0x4A, 65, 0x1B, 0x64, 0x04]);
      expect(feed, greaterThan(0));
      expect(indexOf(escPos, [0x1D, 0x56, 0x42, 0x00]), greaterThan(feed));

      final star = PrinterCommands.receipt(image, PrinterLanguage.starLine, extraFeedMm: 10);
      final starFeed = indexOf(star, [0x1B, 0x2A, 0x72, 0x59, ...'80'.codeUnits, 0x00]);
      expect(starFeed, greaterThan(0));
      expect(indexOf(star, [0x1B, 0x0C, 0x04]), greaterThan(starFeed));

      final prnt = PrinterCommands.receipt(image, PrinterLanguage.starPrnt, extraFeedMm: 5);
      expect(indexOf(prnt, [0x1B, 0x4A, 20, 0x1B, 0x64, 0x03]), greaterThan(0));

      // None by default
      expect(indexOf(PrinterCommands.receipt(image, PrinterLanguage.escPos), [0x1B, 0x4A]), -1);
    });

    test('StarPRNT: ESC GS S graphics, BEL drawer, feed and cut', () {
      final bytes = PrinterCommands.receipt(
        sampleImage(),
        PrinterLanguage.starPrnt,
        openDrawer: true,
      );

      expect(bytes.sublist(0, 2), [0x1B, 0x40]);
      expect(indexOf(bytes, [0x1B, 0x07, 0x14, 0x14, 0x07]), 2);
      expect(indexOf(bytes, [0x1B, 0x1D, 0x53, 0x01, 2, 0, 3, 0, 0x00]), greaterThan(0));
      expect(bytes.sublist(bytes.length - 3), [0x1B, 0x64, 0x03]);
    });

    test('drawer-only commands', () {
      expect(PrinterCommands.drawer(PrinterLanguage.escPos), [
        0x1B, 0x40, 0x1B, 0x70, 0x00, 0x19, 0xFA, //
      ]);
      final star = PrinterCommands.drawer(PrinterLanguage.starLine);
      expect(indexOf(star, [0x1B, 0x2A, 0x72, 0x44, 0x31, 0x00]), 8);
      expect(PrinterCommands.drawer(PrinterLanguage.starPrnt).last, 0x07);
    });
  });

  group('Images', () {
    test('RGBA is made black and white, padded to the paper and trimmed at the bottom', () {
      // 3 x 4: a dark pixel, a light grey one, a transparent black one; last two rows white
      const white = [255, 255, 255, 255];
      final rgba = Uint8List.fromList([
        0, 0, 0, 255, 200, 200, 200, 255, 0, 0, 0, 0, //
        ...white, 20, 20, 20, 255, ...white, //
        ...white, ...white, ...white, //
        ...white, ...white, ...white,
      ]);
      final image = MonoImage.fromRgba(rgba, 3, 4, targetWidth: 16);

      expect(image.width, 16);
      expect(image.bytesPerRow, 2);
      expect(image.height, 2);
      expect(image.bits, [0x80, 0x00, 0x40, 0x00]);
    });

    test('pages are stacked, narrower ones padded', () {
      final narrow = MonoImage(8, 1, Uint8List.fromList([0xAA]));
      final stacked = MonoImage.stack([sampleImage(), narrow]);

      expect(stacked.width, 16);
      expect(stacked.height, 4);
      expect(stacked.row(0), [0xFF, 0xFF]);
      expect(stacked.row(3), [0xAA, 0x00]);
    });
  });

  group('Config', () {
    test('Star printers are recognised by name and USB vendor', () {
      expect(suggestLanguage('TSP143IIIBI-ABC'), PrinterLanguage.starLine);
      expect(suggestLanguage('Star Micronics'), PrinterLanguage.starLine);
      expect(suggestLanguage('USB printer', vendorId: starVendorId), PrinterLanguage.starLine);
      expect(suggestLanguage('mC-Print3-F1A2'), PrinterLanguage.starPrnt);
      expect(suggestLanguage('mPOP'), PrinterLanguage.starPrnt);
      expect(suggestLanguage('SM-L200'), PrinterLanguage.starPrnt);
      expect(suggestLanguage('Printer001'), PrinterLanguage.escPos);
      expect(suggestLanguage('XP-58'), PrinterLanguage.escPos);
    });

    test('round-trips through JSON and knows when it is ready', () {
      const cfg = PrinterConfig(
        connection: PrinterConnection.bluetooth,
        deviceId: '00:11:22:33:44:55',
        deviceName: 'mPOP',
        language: PrinterLanguage.starPrnt,
        paperWidth: PaperWidth.mm58,
        extraFeedMm: 15,
      );
      final back = PrinterConfig.fromJson(cfg.toJson());

      expect(back, cfg);
      expect(back.dotsPerLine, 384);
      expect(back.isReady, isTrue);
      expect(const PrinterConfig(connection: PrinterConnection.network).isReady, isFalse);
      expect(const PrinterConfig(connection: PrinterConnection.usb).isReady, isFalse);
      expect(const PrinterConfig().isReady, isTrue);
      expect(const PrinterConfig().dotsPerLine, 576);
      expect(PrinterConfig.fromJson(const {'extra_feed_mm': 999}).extraFeedMm, 30);
      expect(PrinterConfig.fromJson(const {}), const PrinterConfig());
    });

    test('a narrow (180 dpi) head gets a narrower page', () {
      const narrow = PrinterConfig(narrowPrint: true);
      expect(narrow.dotsPerLine, 512);
      expect(narrow.printableWidthMm, 64);
      expect(const PrinterConfig(paperWidth: PaperWidth.mm58, narrowPrint: true).dotsPerLine, 360);
      expect(PrinterConfig.fromJson(narrow.toJson()).narrowPrint, isTrue);
    });

    test('a raw ESC/POS printer on 80 mm paper prints the full width, or 64 mm narrow', () {
      const escPos = PrinterConfig(connection: PrinterConnection.network, host: '10.0.0.5');
      expect(escPos.dotsPerLine, 576);
      expect(escPos.printableWidthMm, 72);
      expect(escPos.copyWith(narrowPrint: true).dotsPerLine, 512);
      expect(escPos.copyWith(narrowPrint: true).printableWidthMm, 64);
    });

    test('a chosen device fills in the config', () {
      const usb = PrinterDevice(connection: PrinterConnection.usb, id: '1305:1', name: 'TSP143');
      final cfg = usb.applyTo(const PrinterConfig(paperWidth: PaperWidth.mm58));
      expect(cfg.connection, PrinterConnection.usb);
      expect(cfg.deviceId, '1305:1');
      expect(cfg.language, PrinterLanguage.starLine);
      expect(cfg.paperWidth, PaperWidth.mm58);

      const lan = PrinterDevice(
        connection: PrinterConnection.network,
        id: '192.168.1.50',
        name: '192.168.1.50:9100',
      );
      final net = lan.applyTo(const PrinterConfig());
      expect(net.host, '192.168.1.50');
      expect(net.isReady, isTrue);
    });
  });

  group('Transports', () {
    test('SNMP: a GetRequest encodes like net-snmp, a GetResponse is read', () {
      expect(Snmp.getRequest('1.3.6.1.2.1.1.5.0', 1), [
        0x30, 0x26, 0x02, 0x01, 0x00, 0x04, 0x06, ...'public'.codeUnits, //
        0xA0, 0x19, 0x02, 0x01, 0x01, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00, //
        0x30, 0x0E, 0x30, 0x0C, 0x06, 0x08, 0x2B, 6, 1, 2, 1, 1, 5, 0, 0x05, 0x00,
      ]);
      expect(Snmp.parseResponse(snmpResponse(2, 'TM-T20II')), (2, 'TM-T20II'));
      expect(Snmp.parseResponse(snmpResponse(1, null)), (1, null));
      expect(Snmp.parseResponse([0x30, 0x05, 0x02]), isNull);
    });

    test('network printers are named by Star discovery, SNMP or ESC/POS GS I', () async {
      // Answers each UDP request with reply(request), or not at all
      Future<int> udpAgent(List<int>? Function(Uint8List request) reply) async {
        final agent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        agent.listen((event) {
          final request = event == RawSocketEvent.read ? agent.receive() : null;
          final answer = request == null ? null : reply(request.data);
          if (answer != null) agent.send(answer, request!.address, request.port);
        });
        addTearDown(agent.close);
        return agent.port;
      }

      final silent = await udpAgent((_) => null);
      final snmp = await udpAgent((request) {
        final id = request[17]; // request id, with every length one byte
        // hrDeviceDescr missing, then sysName and sysDescr
        return snmpResponse(id, id == 1 ? null : (id == 2 ? 'TM-T20II' : 'EPSON TM'));
      });
      // Trimmed from a TSP143IIILAN's reply
      final star = await udpAgent(
        (request) => [
          ...'STR_BCAST'.codeUnits, ...List.filled(7, 0), ...'RS1.0.1'.codeUnits, //
          ...List.filled(12, 0), ...'RTSP100LAN'.codeUnits, ...List.filled(30, 0),
          ...'Star'.codeUnits, ...List.filled(40, 0),
          ...'TSP143IIILAN (STR_T-001)'.codeUnits, ...List.filled(30, 0),
        ],
      );
      final escPos = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(escPos.close);
      final asked = <int>[];
      escPos.listen(
        (client) => client.listen((data) {
          for (var i = 0; i + 2 < data.length; i += 3) {
            asked.add(data[i + 2]);
            client.add([...(data[i + 2] == 0x43 ? '_BTP-R580II' : '_SNBC').codeUnits, 0]);
          }
        }),
      );
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = closed.port;
      await closed.close();

      final devices = PrinterDevices(listsPaired: false);
      Future<String?> name({int? snmpPort, int? starPort, int? port}) => devices.networkName(
        '127.0.0.1',
        snmpPort: snmpPort ?? silent,
        starPort: starPort ?? silent,
        port: port ?? escPos.port,
        timeout: const Duration(milliseconds: 300),
      );

      expect(await name(starPort: star), 'Star TSP143IIILAN');
      expect(await name(snmpPort: snmp), 'TM-T20II');
      expect(asked, isEmpty, reason: 'Star and SNMP printers are not sent GS I');
      expect(await name(), 'SNBC BTP-R580II');
      expect(asked, [0x43, 0x42]);
      expect(await name(port: closedPort), isNull);
    });

    test('network printers get the bytes over raw TCP', () async {
      final printer = await fakeNetworkPrinter();
      final bytes = Uint8List.fromList(
        PrinterCommands.receipt(sampleImage(), PrinterLanguage.escPos),
      );
      await PrinterDevices().sendNetwork('127.0.0.1', printer.port, bytes);

      expect(await printer.received, bytes);
    });

    test('an unreachable network printer is reported, not thrown raw', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      expect(
        PrinterDevices().sendNetwork('127.0.0.1', port, Uint8List(1)),
        throwsA(
          isA<PrinterException>().having((e) => e.message, 'message', contains('127.0.0.1:$port')),
        ),
      );
    });

    test(
      'Bluetooth: paired Classic printers and nearby LE ones, each sent the right way',
      () async {
        const channel = MethodChannel('thermal_printer_kit');
        final calls = <MethodCall>[];
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'bluetoothPermission' => true,
            'bluetoothDevices' => {
              'enabled': true,
              'devices': [
                {'address': 'AA:BB:CC:DD:EE:FF', 'name': 'RPP02N', 'isPrinter': true},
              ],
            },
            'bleScan' => {
              'enabled': true,
              'devices': [
                // The same dual-mode printer, also seen over LE: listed once, as Classic
                {'id': 'AA:BB:CC:DD:EE:FF', 'name': 'RPP02N', 'isPrinter': true},
                {'id': '1F2E3D4C-0000-4000-8000-000000000001', 'name': 'MPT-II', 'isPrinter': true},
                {'id': '1F2E3D4C-0000-4000-8000-000000000002', 'name': 'Headphones'},
              ],
            },
            _ => null,
          };
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

        final devices = PrinterDevices(listsPaired: true);
        final scan = await devices.bluetoothDevices();

        expect(scan.enabled, isTrue);
        expect(scan.devices.map((d) => d.id), [
          '${PrinterDevice.blePrefix}1F2E3D4C-0000-4000-8000-000000000001',
          'AA:BB:CC:DD:EE:FF',
          '${PrinterDevice.blePrefix}1F2E3D4C-0000-4000-8000-000000000002',
        ]);
        expect(scan.devices.first.isBle, isTrue);
        expect(scan.devices[1].isBle, isFalse);

        await devices.sendBluetooth(scan.devices.first.id, Uint8List.fromList([1, 2]));
        await devices.sendBluetooth('AA:BB:CC:DD:EE:FF', Uint8List.fromList([3]));
        final sends = calls.where((c) => c.method.endsWith('Send')).toList();
        expect(sends[0].method, 'bleSend');
        expect(sends[0].arguments['id'], '1F2E3D4C-0000-4000-8000-000000000001');
        expect(sends[1].method, 'bluetoothSend');
        expect(sends[1].arguments['address'], 'AA:BB:CC:DD:EE:FF');

        // iOS lists only what the LE scan finds
        calls.clear();
        expect((await PrinterDevices(listsPaired: false).bluetoothDevices()).devices, hasLength(3));
        expect(calls.map((c) => c.method), isNot(contains('bluetoothDevices')));
      },
    );

    test('native errors become PrinterExceptions with their code', () async {
      const channel = MethodChannel('thermal_printer_kit');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'permission', message: 'Allow Bluetooth.');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      expect(
        PrinterDevices().sendBluetooth('AA:BB:CC:DD:EE:FF', Uint8List(1)),
        throwsA(
          isA<PrinterException>()
              .having((e) => e.code, 'code', 'permission')
              .having((e) => e.message, 'message', 'Allow Bluetooth.'),
        ),
      );
    });

    test('Windows: an unknown printer fails with a message', () async {
      expect(
        WindowsRawPrinter.send('thermal_printer_kit test printer', Uint8List.fromList([0x1B])),
        throwsA(isA<PrinterException>()),
      );
    }, skip: !Platform.isWindows);
  });

  group('WindowsUsbPrinter', () {
    const snbc = r'\\?\USB#VID_154F&PID_154F#6&164ad6b7&0&2#{744a56c6-63f7-11d3-88bc-5254ab1470fd}';
    const snbcOtherSocket =
        r'\\?\usb#vid_154f&pid_154f#5&d727a80&0&8#{744a56c6-63f7-11d3-88bc-5254ab1470fd}';
    const epson =
        r'\\?\USB#VID_04b8&PID_118a&MI_01#7&37d52ecd&0&0001#{28d78fad-5a12-11d1-ae5b-0000f803a8c2}';

    test('tells a device path from an installed printer name', () {
      expect(WindowsUsbPrinter.isDevicePath(snbc), isTrue);
      expect(WindowsUsbPrinter.isDevicePath('Star TSP143'), isFalse);
      expect(WindowsUsbPrinter.isDevicePath('1359:1359'), isFalse);
    });

    test('names a printer by its maker and USB ids', () {
      expect(WindowsUsbPrinter.nameOf(snbc), 'SNBC USB printer');
      expect(WindowsUsbPrinter.nameOf(epson), 'USB printer');
      expect(WindowsUsbPrinter.addressOf(epson), '04B8:118A');
      expect(WindowsUsbPrinter.addressOf(r'\\?\somewhere'), r'\\?\somewhere');
      expect(WindowsUsbPrinter.vendorIdOf(snbc), 0x154F);
      expect(WindowsUsbPrinter.vendorIdOf(r'\\?\somewhere'), isNull);
    });

    test('finds a saved printer by its path, whatever the case', () {
      expect(WindowsUsbPrinter.pathFor(snbc.toLowerCase(), [epson, snbc]), snbc);
    });

    test('finds a saved printer moved to another USB socket', () {
      expect(WindowsUsbPrinter.pathFor(snbc, [epson, snbcOtherSocket]), snbcOtherSocket);
    });

    test('does not send a job to a different printer', () {
      expect(WindowsUsbPrinter.pathFor(snbc, [epson]), isNull);
      expect(WindowsUsbPrinter.pathFor(snbc, []), isNull);
    });

    test('lays a GUID out as Windows does', () {
      expect(WindowsUsbPrinter.guidBytes('28d78fad-5a12-11d1-ae5b-0000f803a8c2'), [
        0xad, 0x8f, 0xd7, 0x28, 0x12, 0x5a, 0xd1, 0x11, //
        0xae, 0x5b, 0x00, 0x00, 0xf8, 0x03, 0xa8, 0xc2,
      ]);
    });

    test('a printer that is not connected fails with a message', () async {
      const missing =
          r'\\?\USB#VID_FFFF&PID_FFFF#1&2&3#{28d78fad-5a12-11d1-ae5b-0000f803a8c2}';
      expect(
        WindowsUsbPrinter.send(missing, Uint8List.fromList([0x1B])),
        throwsA(isA<PrinterException>().having((e) => e.code, 'code', 'not_found')),
      );
    }, skip: !Platform.isWindows);
  });

  group('ThermalPrinter', () {
    test('sends an image with the feed, cut and drawer to a network printer', () async {
      final printer = await fakeNetworkPrinter();
      final cfg = PrinterConfig(
        connection: PrinterConnection.network,
        host: '127.0.0.1',
        port: printer.port,
        language: PrinterLanguage.starPrnt,
        extraFeedMm: 5,
      );
      await ThermalPrinter().printMonoImage(cfg, sampleImage(), openDrawer: true);

      expect(
        await printer.received,
        PrinterCommands.receipt(
          sampleImage(),
          PrinterLanguage.starPrnt,
          openDrawer: true,
          extraFeedMm: 5,
        ),
      );
    });

    test('opens the cash drawer', () async {
      final printer = await fakeNetworkPrinter();
      final cfg = PrinterConfig(
        connection: PrinterConnection.network,
        host: '127.0.0.1',
        port: printer.port,
      );
      await ThermalPrinter().openCashDrawer(cfg);
      expect(await printer.received, PrinterCommands.drawer(PrinterLanguage.escPos));
    });

    test('refuses to print without a printer, and raw bytes to a non-raw printer', () {
      expect(
        () => ThermalPrinter().sendRaw(const PrinterConfig(connection: PrinterConnection.usb), [0]),
        throwsA(isA<PrinterException>().having((e) => e.code, 'code', 'not_ready')),
      );
      expect(
        () => ThermalPrinter().sendRaw(const PrinterConfig(), [0]),
        throwsA(isA<PrinterException>().having((e) => e.code, 'code', 'unsupported')),
      );
    });

    test('the page format is as wide as the printable area', () async {
      const cfg = PrinterConfig(paperWidth: PaperWidth.mm58);
      expect(cfg.pageFormat.width, closeTo(48 * 72 / 25.4, 0.01));
      final doc = pw.Document()
        ..addPage(pw.Page(pageFormat: cfg.pageFormat, build: (_) => pw.Text('Hello')));
      expect(String.fromCharCodes((await doc.save()).take(5)), '%PDF-');
    });
  });
}
