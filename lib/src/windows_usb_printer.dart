import 'dart:typed_data';

import 'printer_device.dart';
import 'windows_usb_native.dart'
    if (dart.library.js_interop) 'windows_usb_native_web.dart'
    as native;

/// Finds printers plugged into a Windows PC by USB and sends them bytes
/// directly, without a Windows printer driver or print queue. Windows only.
///
/// A receipt printer with only its USB port driver installed has no print
/// queue, so the spooler never lists it. It is reached here by its device
/// path (`\\?\USB#VID_154F&PID_154F#…`) instead.
class WindowsUsbPrinter {
  WindowsUsbPrinter._();

  /// Windows' own USB printer driver (usbprint.sys), which most printers get
  /// when no vendor driver is installed.
  static const _usbPrintInterface = '28d78fad-5a12-11d1-ae5b-0000f803a8c2';

  /// SNBC's USB port driver (BYPUSB.sys), for its BTP printers.
  static const _snbcInterface = '744a56c6-63f7-11d3-88bc-5254ab1470fd';

  /// How long [send] waits for the printer to take a job. A printer out of
  /// paper stops taking data without reporting an error.
  static const sendTimeout = Duration(seconds: 30);

  static const _chunkSize = 4096;

  /// The device paths of the USB printers connected now.
  static List<String> devicePaths() => [
    ..._pathsOf(_snbcInterface),
    ..._pathsOf(_usbPrintInterface),
  ];

  /// Whether [id] is a device path from [devicePaths], rather than the name of
  /// an installed printer.
  static bool isDevicePath(String id) => id.startsWith(r'\\?\');

  /// A name for the printer at [path], with its maker when known.
  static String nameOf(String path) => _isSnbc(path) ? 'SNBC USB printer' : 'USB printer';

  /// The USB vendor and product id in [path], as `154F:154F`, to show in place
  /// of the path.
  static String addressOf(String path) {
    final ids = _ids.firstMatch(path);
    return ids == null ? path : '${ids[1]}:${ids[2]}'.toUpperCase();
  }

  /// The USB vendor id in [path], or null if it has none.
  static int? vendorIdOf(String path) {
    final ids = _ids.firstMatch(path);
    return ids == null ? null : int.parse(ids[1]!, radix: 16);
  }

  /// The path to open for the printer saved as [saved], from those
  /// [connected]. A device path names the USB socket, so a printer moved to
  /// another socket is found by its vendor and product id instead.
  static String? pathFor(String saved, List<String> connected) {
    for (final path in connected) {
      if (path.toLowerCase() == saved.toLowerCase()) return path;
    }
    for (final path in connected) {
      if (_modelOf(path) == _modelOf(saved)) return path;
    }
    return null;
  }

  /// Sends [bytes] to the printer whose device path is [path]. Throws a
  /// [PrinterException] when the printer isn't connected or doesn't take the
  /// whole job within [sendTimeout].
  static Future<void> send(String path, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    // Writing blocks while the printer is busy, which would freeze the app on
    // the UI thread.
    await native
        .runInBackground(() => _sendSync(path, bytes))
        .timeout(
          sendTimeout,
          onTimeout: () =>
              throw const PrinterException('The USB printer stopped taking data. Check its paper.'),
        );
  }

  /// [guid] (`28d78fad-5a12-…`) laid out as a Windows GUID struct, whose first
  /// three fields are little-endian.
  static Uint8List guidBytes(String guid) {
    final hex = guid.replaceAll('-', '');
    final b = [for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    return Uint8List.fromList([b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], ...b.sublist(8)]);
  }

  static final _ids = RegExp(r'vid_([0-9a-f]{4})&pid_([0-9a-f]{4})', caseSensitive: false);

  /// A device path without the part that names the USB socket:
  /// `\\?\usb#vid_154f&pid_154f#<socket>#{interface}`.
  static String _modelOf(String path) {
    final parts = path.toLowerCase().split('#');
    return parts.length < 4 ? path.toLowerCase() : '${parts[1]}#${parts.last}';
  }

  static bool _isSnbc(String path) => path.toLowerCase().endsWith('{$_snbcInterface}');

  /// The device paths of connected devices with the [interface] GUID.
  static List<String> _pathsOf(String interface) => native.devicePaths(guidBytes(interface));

  static void _sendSync(String saved, Uint8List data) {
    final path = pathFor(saved, devicePaths());
    if (path == null) {
      throw const PrinterException('The USB printer is not connected.', code: 'not_found');
    }

    // SNBC's driver takes print data on its first pipe, and refuses it on the
    // device itself.
    native.write(_isSnbc(path) ? '$path\\PIPE00' : path, data, _chunkSize);
  }
}
