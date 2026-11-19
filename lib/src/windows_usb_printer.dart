import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'printer_device.dart';

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
    await Isolate.run(() => _sendSync(path, bytes)).timeout(
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
  static List<String> _pathsOf(String interface) {
    final guid = calloc<Uint8>(16);
    final length = calloc<Uint32>();
    try {
      guid.asTypedList(16).setAll(0, guidBytes(interface));
      if (_listSize(length, guid, nullptr, 0) != 0 || length.value <= 1) return const [];
      final buffer = calloc<Uint16>(length.value);
      try {
        if (_list(guid, nullptr, buffer, length.value, 0) != 0) return const [];
        // The paths come back one after another, each ending in a zero.
        return String.fromCharCodes(
          buffer.asTypedList(length.value),
        ).split('\x00').where((path) => path.isNotEmpty).toList();
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(length);
      calloc.free(guid);
    }
  }

  static void _sendSync(String saved, Uint8List data) {
    final path = pathFor(saved, devicePaths());
    if (path == null) {
      throw const PrinterException('The USB printer is not connected.', code: 'not_found');
    }

    // SNBC's driver takes print data on its first pipe, and refuses it on the
    // device itself.
    final target = (_isSnbc(path) ? '$path\\PIPE00' : path).toNativeUtf16();
    final buffer = calloc<Uint8>(_chunkSize);
    final written = calloc<Uint32>();
    try {
      final handle = _createFile(
        target,
        0x40000000, // GENERIC_WRITE
        3, // FILE_SHARE_READ | FILE_SHARE_WRITE
        nullptr,
        3, // OPEN_EXISTING
        0,
        0,
      );
      if (handle == -1) throw const PrinterException('Windows could not open the USB printer.');
      try {
        var sent = 0;
        while (sent < data.length) {
          final size = data.length - sent < _chunkSize ? data.length - sent : _chunkSize;
          buffer.asTypedList(size).setRange(0, size, data, sent);
          if (_writeFile(handle, buffer, size, written, nullptr) == 0 || written.value == 0) {
            throw const PrinterException('The USB printer refused the print job.');
          }
          sent += written.value;
        }
      } finally {
        _closeHandle(handle);
      }
    } finally {
      calloc.free(written);
      calloc.free(buffer);
      calloc.free(target);
    }
  }
}

final _cfgmgr32 = DynamicLibrary.open('cfgmgr32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _listSize = _cfgmgr32
    .lookupFunction<
      Uint32 Function(Pointer<Uint32>, Pointer<Uint8>, Pointer<Utf16>, Uint32),
      int Function(Pointer<Uint32>, Pointer<Uint8>, Pointer<Utf16>, int)
    >('CM_Get_Device_Interface_List_SizeW');

final _list = _cfgmgr32
    .lookupFunction<
      Uint32 Function(Pointer<Uint8>, Pointer<Utf16>, Pointer<Uint16>, Uint32, Uint32),
      int Function(Pointer<Uint8>, Pointer<Utf16>, Pointer<Uint16>, int, int)
    >('CM_Get_Device_Interface_ListW');

final _createFile = _kernel32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
      int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
    >('CreateFileW');

final _writeFile = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
    >('WriteFile');

final _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
  'CloseHandle',
);
