import 'dart:typed_data';

import 'mono_image.dart';
import 'printer_config.dart';

/// Turns an image into printer commands, in each [PrinterLanguage].
class PrinterCommands {
  PrinterCommands._();

  /// Rows per ESC/POS or StarPRNT image command. Many printers have a small
  /// buffer, so an image is sent as a stack of strips.
  static const bandHeight = 128;

  /// Prints [image] [copies] times, each followed by [extraFeedMm] of blank
  /// paper and a partial cut. With [openDrawer], the cash drawer wired to the
  /// printer opens first.
  static List<int> receipt(
    MonoImage image,
    PrinterLanguage language, {
    int copies = 1,
    bool openDrawer = false,
    int extraFeedMm = 0,
  }) {
    final out = BytesBuilder(copy: false);
    switch (language) {
      case PrinterLanguage.escPos:
        out.add(const [0x1B, 0x40]); // ESC @ initialise
        if (openDrawer) out.add(_escPosDrawer);
        for (var c = 0; c < copies; c++) {
          _escPosImage(out, image);
          _escPosFeed(out, extraFeedMm);
          out.add(const [0x1B, 0x64, 0x04]); // ESC d 4: feed 4 lines
          out.add(const [0x1D, 0x56, 0x42, 0x00]); // GS V 66 0: feed to cutter, partial cut
        }
      case PrinterLanguage.starLine:
        out.add(const [0x1B, 0x2A, 0x72, 0x52]); // ESC * r R initialise raster mode
        out.add(const [0x1B, 0x2A, 0x72, 0x41]); // ESC * r A enter raster mode
        // Set here rather than left to the printer's memory switches, which can
        // hold a page length (a long blank feed after every job)
        out.add(const [0x1B, 0x2A, 0x72, 0x50, 0x30, 0x00]); // ESC * r P "0" NUL: continuous paper
        out.add(const [
          0x1B,
          0x2A,
          0x72,
          0x45,
          0x31,
          0x33,
          0x00,
        ]); // ESC * r E "13" NUL: EOT feeds, partial cut
        // Only acted on while the image buffer is empty, so before the image
        if (openDrawer) out.add(_starRasterDrawer);
        for (var c = 0; c < copies; c++) {
          _starRasterImage(out, image);
          if (extraFeedMm > 0) {
            // ESC * r Y n NUL: feed n dot rows (n is ASCII), 8 per mm
            out.add([0x1B, 0x2A, 0x72, 0x59, ...'${extraFeedMm * 8}'.codeUnits, 0x00]);
          }
          out.add(const [0x1B, 0x0C, 0x04]); // ESC FF EOT: print, feed to the cutter and cut
        }
        out.add(const [0x1B, 0x2A, 0x72, 0x42]); // ESC * r B quit raster mode
      case PrinterLanguage.starPrnt:
        out.add(const [0x1B, 0x40]); // ESC @ initialise
        if (openDrawer) out.add(_starPrntDrawer);
        for (var c = 0; c < copies; c++) {
          _starPrntImage(out, image);
          // ESC J n: feed n/4 mm
          for (var quarters = extraFeedMm * 4; quarters > 0; quarters -= 255) {
            out.add([0x1B, 0x4A, quarters.clamp(1, 255)]);
          }
          out.add(const [0x1B, 0x64, 0x03]); // ESC d 3: feed to cutter, partial cut
        }
    }
    return out.takeBytes();
  }

  /// Opens the cash drawer wired to the printer (drawer kick-out port).
  static List<int> drawer(PrinterLanguage language) => switch (language) {
    PrinterLanguage.escPos => [0x1B, 0x40, ..._escPosDrawer],
    PrinterLanguage.starLine => [
      0x1B, 0x2A, 0x72, 0x52, // ESC * r R
      0x1B, 0x2A, 0x72, 0x41, // ESC * r A
      ..._starRasterDrawer,
      0x1B, 0x2A, 0x72, 0x42, // ESC * r B
    ],
    PrinterLanguage.starPrnt => [0x1B, 0x40, ..._starPrntDrawer],
  };

  // ESC p 0 25 250: pulse pin 2 for 50 ms, then wait 500 ms
  static const _escPosDrawer = [0x1B, 0x70, 0x00, 0x19, 0xFA];

  // ESC * r D 1 NUL: drive external device 1 (n is ASCII)
  static const _starRasterDrawer = [0x1B, 0x2A, 0x72, 0x44, 0x31, 0x00];

  // ESC BEL 20 20 (200 ms pulse, 200 ms delay), then BEL: drive external device 1
  static const _starPrntDrawer = [0x1B, 0x07, 0x14, 0x14, 0x07];

  /// ESC J n: feed n dot rows (1/203 inch on most printers), 8 per mm.
  static void _escPosFeed(BytesBuilder out, int mm) {
    for (var dots = mm * 8; dots > 0; dots -= 255) {
      out.add([0x1B, 0x4A, dots.clamp(1, 255)]);
    }
  }

  /// GS v 0: raster bit image, in strips.
  static void _escPosImage(BytesBuilder out, MonoImage image) {
    final bpr = image.bytesPerRow;
    for (var top = 0; top < image.height; top += bandHeight) {
      final rows = (image.height - top).clamp(0, bandHeight);
      out.add([0x1D, 0x76, 0x30, 0x00, bpr & 0xFF, bpr >> 8, rows & 0xFF, rows >> 8]);
      out.add(Uint8List.sublistView(image.bits, top * bpr, (top + rows) * bpr));
    }
  }

  /// `b n1 n2 data` per row (automatic line feed). Trailing white bytes are
  /// left off, which roughly halves what goes over Bluetooth.
  static void _starRasterImage(BytesBuilder out, MonoImage image) {
    for (var y = 0; y < image.height; y++) {
      final row = image.row(y);
      var k = row.length;
      while (k > 1 && row[k - 1] == 0) {
        k--;
      }
      out.add([0x62, k & 0xFF, k >> 8]);
      out.add(Uint8List.sublistView(row, 0, k));
    }
  }

  /// ESC GS S 1 xL xH yL yH 0 data: monochrome raster graphics, in strips.
  static void _starPrntImage(BytesBuilder out, MonoImage image) {
    final bpr = image.bytesPerRow;
    for (var top = 0; top < image.height; top += bandHeight) {
      final rows = (image.height - top).clamp(0, bandHeight);
      out.add([0x1B, 0x1D, 0x53, 0x01, bpr & 0xFF, bpr >> 8, rows & 0xFF, rows >> 8, 0x00]);
      out.add(Uint8List.sublistView(image.bits, top * bpr, (top + rows) * bpr));
    }
  }
}
