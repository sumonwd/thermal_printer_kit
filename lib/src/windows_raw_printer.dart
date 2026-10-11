import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'printer_device.dart';

/// `DOC_INFO_1W` from winspool.h.
final class _DocInfo1 extends Struct {
  external Pointer<Utf16> pDocName;
  external Pointer<Utf16> pOutputFile;
  external Pointer<Utf16> pDatatype;
}

typedef _OpenPrinterC =
    Int32 Function(Pointer<Utf16> name, Pointer<IntPtr> handle, Pointer<Void> defaults);
typedef _OpenPrinterDart =
    int Function(Pointer<Utf16> name, Pointer<IntPtr> handle, Pointer<Void> defaults);
typedef _StartDocC = Uint32 Function(IntPtr handle, Uint32 level, Pointer<_DocInfo1> info);
typedef _StartDocDart = int Function(int handle, int level, Pointer<_DocInfo1> info);
typedef _HandleC = Int32 Function(IntPtr handle);
typedef _HandleDart = int Function(int handle);
typedef _WriteC =
    Int32 Function(IntPtr handle, Pointer<Uint8> data, Uint32 size, Pointer<Uint32> written);
typedef _WriteDart =
    int Function(int handle, Pointer<Uint8> data, int size, Pointer<Uint32> written);

/// Sends bytes to an installed Windows printer as a RAW spooler job, so the
/// driver passes ESC/POS or Star commands straight to a USB (or Bluetooth COM)
/// printer. Windows only.
class WindowsRawPrinter {
  WindowsRawPrinter._();

  /// Sends [bytes] to the installed printer named [printerName]. Throws a
  /// [PrinterException] when Windows can't open the printer or it refuses the
  /// job.
  static Future<void> send(
    String printerName,
    Uint8List bytes, {
    String documentName = 'Receipt',
  }) async {
    final lib = DynamicLibrary.open('winspool.drv');
    final openPrinter = lib.lookupFunction<_OpenPrinterC, _OpenPrinterDart>('OpenPrinterW');
    final startDoc = lib.lookupFunction<_StartDocC, _StartDocDart>('StartDocPrinterW');
    final startPage = lib.lookupFunction<_HandleC, _HandleDart>('StartPagePrinter');
    final write = lib.lookupFunction<_WriteC, _WriteDart>('WritePrinter');
    final endPage = lib.lookupFunction<_HandleC, _HandleDart>('EndPagePrinter');
    final endDoc = lib.lookupFunction<_HandleC, _HandleDart>('EndDocPrinter');
    final closePrinter = lib.lookupFunction<_HandleC, _HandleDart>('ClosePrinter');

    final arena = Arena();
    try {
      final handlePtr = arena<IntPtr>();
      if (openPrinter(printerName.toNativeUtf16(allocator: arena), handlePtr, nullptr) == 0) {
        throw PrinterException('Windows could not open the printer "$printerName".');
      }
      final handle = handlePtr.value;
      try {
        final info = arena<_DocInfo1>()
          ..ref.pDocName = documentName.toNativeUtf16(allocator: arena)
          ..ref.pOutputFile = nullptr
          ..ref.pDatatype = 'RAW'.toNativeUtf16(allocator: arena);
        if (startDoc(handle, 1, info) == 0) {
          throw PrinterException('"$printerName" refused the print job. Is it online?');
        }
        try {
          startPage(handle);
          final data = arena<Uint8>(bytes.length);
          data.asTypedList(bytes.length).setAll(0, bytes);
          final written = arena<Uint32>();
          if (write(handle, data, bytes.length, written) == 0 || written.value != bytes.length) {
            throw PrinterException('Windows could not send the job to "$printerName".');
          }
          endPage(handle);
        } finally {
          endDoc(handle);
        }
      } finally {
        closePrinter(handle);
      }
    } finally {
      arena.releaseAll();
    }
  }
}
