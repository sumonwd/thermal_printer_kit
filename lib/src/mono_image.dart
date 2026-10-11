import 'dart:typed_data';

/// A 1-bit image, 8 pixels per byte, most significant bit first, 1 = black:
/// what thermal printers print.
class MonoImage {
  /// Width in dots.
  final int width;

  /// Height in dots.
  final int height;

  /// The rows, [bytesPerRow] bytes each.
  final Uint8List bits;

  /// Wraps packed rows. [bits] must hold `((width + 7) >> 3) * height` bytes.
  MonoImage(this.width, this.height, this.bits)
    : assert(bits.length == ((width + 7) >> 3) * height);

  /// Bytes in one row.
  int get bytesPerRow => (width + 7) >> 3;

  /// Row [y], as a view of [bits].
  Uint8List row(int y) => Uint8List.sublistView(bits, y * bytesPerRow, (y + 1) * bytesPerRow);

  /// Converts an RGBA raster to black and white, cropped or padded to
  /// [targetWidth] dots, with blank rows at the bottom removed. Pixels darker
  /// than [threshold] (0-255) print; transparent pixels are paper.
  factory MonoImage.fromRgba(
    Uint8List rgba,
    int width,
    int height, {
    int? targetWidth,
    int threshold = 160,
  }) {
    final w = targetWidth ?? width;
    final bpr = (w + 7) >> 3;
    final bits = Uint8List(bpr * height);
    var lastInk = -1;
    for (var y = 0; y < height; y++) {
      var rowInk = false;
      for (var x = 0; x < w && x < width; x++) {
        final o = (y * width + x) * 4;
        final a = rgba[o + 3];
        final lum = a < 64 ? 255 : (rgba[o] * 299 + rgba[o + 1] * 587 + rgba[o + 2] * 114) ~/ 1000;
        if (lum < threshold) {
          bits[y * bpr + (x >> 3)] |= 0x80 >> (x & 7);
          rowInk = true;
        }
      }
      if (rowInk) lastInk = y;
    }
    final h = lastInk + 1;
    return MonoImage(w, h, Uint8List.sublistView(bits, 0, bpr * h));
  }

  /// [images] one below the other, as wide as the widest (narrower ones are
  /// padded with paper on the right).
  factory MonoImage.stack(List<MonoImage> images) {
    if (images.length == 1) return images.first;
    final width = images.fold(0, (w, i) => i.width > w ? i.width : w);
    final bpr = (width + 7) >> 3;
    final height = images.fold(0, (h, i) => h + i.height);
    final bits = Uint8List(bpr * height);
    var y = 0;
    for (final image in images) {
      for (var r = 0; r < image.height; r++, y++) {
        bits.setRange(y * bpr, y * bpr + image.bytesPerRow, image.row(r));
      }
    }
    return MonoImage(width, height, bits);
  }
}
