import 'dart:typed_data';

import 'printer_device.dart';

/// Web stand-in for the Windows spooler printer in `windows_raw_printer.dart`.
class WindowsRawPrinter {
  WindowsRawPrinter._();

  /// Always throws a [PrinterException]: there is no Windows spooler on the web.
  static Future<void> send(
    String printerName,
    Uint8List bytes, {
    String documentName = 'Receipt',
  }) async =>
      throw const PrinterException('Installed printers are not supported in a web browser.');
}
