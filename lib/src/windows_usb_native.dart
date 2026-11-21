import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'printer_device.dart';

// Windows calls behind [WindowsUsbPrinter]. Kept apart so the class still
// compiles on the web, where `windows_usb_native_web.dart` replaces this file.

/// Runs [task] off the UI thread: writing blocks while the printer is busy.
Future<void> runInBackground(void Function() task) => Isolate.run(task);

/// The device paths of connected devices with the interface GUID
/// [interfaceGuid] (a Windows GUID struct, 16 bytes).
List<String> devicePaths(Uint8List interfaceGuid) {
  final guid = calloc<Uint8>(16);
  final length = calloc<Uint32>();
  try {
    guid.asTypedList(16).setAll(0, interfaceGuid);
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

/// Writes [data] to the device at [target], [chunkSize] bytes at a time.
void write(String target, Uint8List data, int chunkSize) {
  final path = target.toNativeUtf16();
  final buffer = calloc<Uint8>(chunkSize);
  final written = calloc<Uint32>();
  try {
    final handle = _createFile(
      path,
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
        final size = data.length - sent < chunkSize ? data.length - sent : chunkSize;
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
    calloc.free(path);
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
