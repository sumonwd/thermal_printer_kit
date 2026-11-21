import 'dart:typed_data';

import 'printer_device.dart';

// Web stand-in for `windows_usb_native.dart`: browsers can't reach USB
// printers this way, so none are found and sending fails.

/// Runs [task] at once: the web has no isolates to move it to.
Future<void> runInBackground(void Function() task) async => task();

/// None: browsers can't list USB printers this way.
List<String> devicePaths(Uint8List interfaceGuid) => const [];

/// Always throws a [PrinterException].
void write(String target, Uint8List data, int chunkSize) =>
    throw const PrinterException('USB printers are not supported in a web browser.');
