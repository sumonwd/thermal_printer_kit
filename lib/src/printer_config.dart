import 'package:pdf/pdf.dart';

/// How a print job reaches the printer.
enum PrinterConnection {
  /// Bluetooth printer: paired Bluetooth Classic (SPP) printers and Bluetooth
  /// LE printers on Android, Bluetooth LE printers on iOS.
  bluetooth,

  /// USB printer: USB OTG on Android, an installed printer on Windows that is
  /// sent a RAW spooler job.
  usb,

  /// LAN / Wi-Fi printer, raw TCP (port 9100 on most printers). Every platform.
  network,

  /// An installed printer driver, sent a PDF without a dialog (Windows, macOS,
  /// Linux).
  driver,

  /// The operating system's print dialog. Every platform.
  system,
}

/// The command language of a thermal printer. Jobs are always sent as an
/// image, so only the image, feed, cut and drawer commands differ.
enum PrinterLanguage {
  /// Epson ESC/POS: most thermal printers (Epson, Xprinter, Rongta, Sunmi,
  /// HPRT, ...) and Star printers switched to ESC/POS emulation.
  escPos,

  /// Star Line / Star Graphic raster mode: TSP100 (TSP143), TSP650II,
  /// TSP700II, TSP800II, SP700.
  starLine,

  /// StarPRNT: mC-Print2, mC-Print3, mPOP, SM-L200/L300, SM-S, SM-T.
  starPrnt,
}

/// Names to show for a [PrinterLanguage].
extension PrinterLanguageLabel on PrinterLanguage {
  /// A short name, such as `ESC/POS (Epson compatible)`.
  String get label => switch (this) {
    PrinterLanguage.escPos => 'ESC/POS (Epson compatible)',
    PrinterLanguage.starLine => 'Star Line / Star Graphic',
    PrinterLanguage.starPrnt => 'StarPRNT',
  };

  /// Printer models that speak this language.
  String get models => switch (this) {
    PrinterLanguage.escPos => 'Most thermal printers, and Star printers in ESC/POS mode',
    PrinterLanguage.starLine => 'Star TSP100 / TSP143, TSP650II, TSP700II, TSP800II, SP700',
    PrinterLanguage.starPrnt => 'Star mC-Print2/3, mPOP, SM-L200/L300, SM-S, SM-T',
  };
}

/// Guesses the command language from a printer's name (and USB vendor id).
PrinterLanguage suggestLanguage(String name, {int? vendorId}) {
  final n = name.toLowerCase().replaceAll(' ', '');
  const starPrnt = ['mpop', 'mc-print', 'mcprint', 'mcp2', 'mcp3', 'sm-l', 'sm-s', 'sm-t'];
  if (starPrnt.any(n.contains)) return PrinterLanguage.starPrnt;
  const star = ['star', 'tsp', 'sp7'];
  if (vendorId == starVendorId || star.any(n.contains)) return PrinterLanguage.starLine;
  return PrinterLanguage.escPos;
}

/// Star Micronics' USB vendor id.
const starVendorId = 0x0519;

/// Roll paper width.
enum PaperWidth {
  /// 58 mm paper: 384 dots across on a 203 dpi head.
  mm58('58mm'),

  /// 80 mm paper: 576 dots across on a 203 dpi head.
  mm80('80mm');

  const PaperWidth(this.label);

  /// `58mm` or `80mm`, also the value stored by [PrinterConfig.toJson].
  final String label;
}

/// A printer and how to reach it. Save it with [toJson] to remember the
/// printer between app launches.
class PrinterConfig {
  /// How jobs reach the printer.
  final PrinterConnection connection;

  /// The chosen `PrinterDevice.id`: a Bluetooth MAC address (Classic), `ble:`
  /// plus the id of a Bluetooth LE printer, USB `vendorId:productId`
  /// (Android), a Windows printer name (USB on Windows) or the driver
  /// printer's URL.
  final String? deviceId;

  /// The chosen printer's name, for display.
  final String? deviceName;

  /// Network printer's IP address or host name.
  final String host;

  /// Network printer's TCP port.
  final int port;

  /// The printer's command language (raw printers only).
  final PrinterLanguage language;

  /// Roll paper width.
  final PaperWidth paperWidth;

  /// Whether the print head is the narrower 180 dpi kind (Epson TM-T88 and
  /// TM-T82, some Xprinter and Rongta models): 512 dots on 80 mm paper, 360 on
  /// 58 mm. A job drawn for a 203 dpi head is cut off on the right there.
  final bool narrowPrint;

  /// Blank paper fed after each copy, before the cut, in millimetres (raw
  /// printers): room to tear off cleanly, or a cutter that sits far from the
  /// head.
  final int extraFeedMm;

  /// Creates a printer configuration. The default is the system print dialog.
  const PrinterConfig({
    this.connection = PrinterConnection.system,
    this.deviceId,
    this.deviceName,
    this.host = '',
    this.port = 9100,
    this.language = PrinterLanguage.escPos,
    this.paperWidth = PaperWidth.mm80,
    this.narrowPrint = false,
    this.extraFeedMm = 0,
  });

  /// The largest [extraFeedMm] [fromJson] accepts.
  static const maxExtraFeedMm = 30;

  /// Thermal printers that take raw commands (and can open a cash drawer).
  bool get isRaw =>
      connection == PrinterConnection.bluetooth ||
      connection == PrinterConnection.usb ||
      connection == PrinterConnection.network;

  /// Dots the head prints across: 576 / 384 at 203 dpi (72 / 48 mm), or
  /// 512 / 360 on a narrower 180 dpi head ([narrowPrint]).
  int get dotsPerLine => switch ((paperWidth, narrowPrint)) {
    (PaperWidth.mm80, false) => 576,
    (PaperWidth.mm80, true) => 512,
    (PaperWidth.mm58, false) => 384,
    (PaperWidth.mm58, true) => 360,
  };

  /// Width to lay a job out at, in millimetres at 8 dots/mm. It is rasterised
  /// at that density, so the image is exactly [dotsPerLine] wide.
  double get printableWidthMm => dotsPerLine / 8;

  /// A roll-paper page as wide as the printable area, of any length: lay PDFs
  /// out on it for `ThermalPrinter.printPdf`.
  PdfPageFormat get pageFormat =>
      PdfPageFormat(printableWidthMm * PdfPageFormat.mm, double.infinity, marginAll: 0);

  /// Whether the configuration is complete enough to print.
  bool get isReady => switch (connection) {
    PrinterConnection.network => host.trim().isNotEmpty && port > 0,
    PrinterConnection.bluetooth ||
    PrinterConnection.usb ||
    PrinterConnection.driver => deviceId?.isNotEmpty ?? false,
    PrinterConnection.system => true,
  };

  /// A copy with the given fields replaced. [clearDevice] forgets the chosen
  /// device (when switching connections).
  PrinterConfig copyWith({
    PrinterConnection? connection,
    String? deviceId,
    String? deviceName,
    bool clearDevice = false,
    String? host,
    int? port,
    PrinterLanguage? language,
    PaperWidth? paperWidth,
    bool? narrowPrint,
    int? extraFeedMm,
  }) {
    return PrinterConfig(
      connection: connection ?? this.connection,
      deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
      deviceName: clearDevice ? null : (deviceName ?? this.deviceName),
      host: host ?? this.host,
      port: port ?? this.port,
      language: language ?? this.language,
      paperWidth: paperWidth ?? this.paperWidth,
      narrowPrint: narrowPrint ?? this.narrowPrint,
      extraFeedMm: extraFeedMm ?? this.extraFeedMm,
    );
  }

  /// A JSON-safe map, read back by [PrinterConfig.fromJson].
  Map<String, dynamic> toJson() => {
    'connection': connection.name,
    'device_id': deviceId,
    'device_name': deviceName,
    'host': host,
    'port': port,
    'language': language.name,
    'paper_size': paperWidth.label,
    'narrow_print': narrowPrint,
    'extra_feed_mm': extraFeedMm,
  };

  /// Reads a map written by [toJson]. Missing or unknown values fall back to
  /// the defaults.
  factory PrinterConfig.fromJson(Map json) {
    T byName<T extends Enum>(List<T> values, dynamic name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    return PrinterConfig(
      connection: byName(PrinterConnection.values, json['connection'], PrinterConnection.system),
      deviceId: json['device_id']?.toString(),
      deviceName: json['device_name']?.toString(),
      host: json['host']?.toString() ?? '',
      port: int.tryParse('${json['port']}') ?? 9100,
      language: byName(PrinterLanguage.values, json['language'], PrinterLanguage.escPos),
      paperWidth: json['paper_size'] == PaperWidth.mm58.label ? PaperWidth.mm58 : PaperWidth.mm80,
      narrowPrint: json['narrow_print'] == true,
      extraFeedMm: (int.tryParse('${json['extra_feed_mm']}') ?? 0).clamp(0, maxExtraFeedMm),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PrinterConfig &&
      other.connection == connection &&
      other.deviceId == deviceId &&
      other.deviceName == deviceName &&
      other.host == host &&
      other.port == port &&
      other.language == language &&
      other.paperWidth == paperWidth &&
      other.narrowPrint == narrowPrint &&
      other.extraFeedMm == extraFeedMm;

  @override
  int get hashCode => Object.hash(
    connection,
    deviceId,
    deviceName,
    host,
    port,
    language,
    paperWidth,
    narrowPrint,
    extraFeedMm,
  );

  @override
  String toString() => 'PrinterConfig(${toJson()})';
}
