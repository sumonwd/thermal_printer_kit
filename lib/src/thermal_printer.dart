import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'mono_image.dart';
import 'printer_commands.dart';
import 'printer_config.dart';
import 'printer_device.dart';
import 'printer_devices.dart';

/// Prints on the printer a [PrinterConfig] describes:
///
/// - Bluetooth, USB and network thermal printers get the job as an image in
///   their command language (ESC/POS, Star Line or StarPRNT), then a cut, and
///   can open the cash drawer.
/// - Driver printers (desktop) and the system print dialog get a PDF.
///
/// Because raw printers get an image, any font, language or layout prints
/// the way it was drawn: build the job as a PDF (with the `pdf` package) or
/// draw it with Flutter and pass a `ui.Image`.
///
/// Failures throw a [PrinterException] whose message can be shown to the user.
class ThermalPrinter {
  /// Creates a printer front end. Pass [devices] to fake the transports in
  /// tests.
  ThermalPrinter({PrinterDevices? devices}) : devices = devices ?? PrinterDevices();

  /// Discovery and transports.
  final PrinterDevices devices;

  /// Prints [pdf], best laid out on [PrinterConfig.pageFormat].
  ///
  /// Raw printers get every page rasterised at 203 dpi, one below the other,
  /// then fed and cut, [copies] times; with [openDrawer] the cash drawer opens
  /// first. Driver printers get [copies] jobs. The system dialog opens once
  /// (copies are chosen there) and this returns false if it is cancelled.
  Future<bool> printPdf(
    PrinterConfig config,
    Uint8List pdf, {
    String name = 'Receipt',
    int copies = 1,
    bool openDrawer = false,
  }) async {
    _checkReady(config);
    switch (config.connection) {
      case PrinterConnection.system:
        return Printing.layoutPdf(
          onLayout: (_) async => pdf,
          name: name,
          format: config.pageFormat,
        );
      case PrinterConnection.driver:
        final printer = (await Printing.listPrinters()).where((p) => p.url == config.deviceId);
        if (printer.isEmpty) {
          throw PrinterException(
            '"${config.deviceName ?? 'The printer'}" was not found. Choose it again.',
            code: 'not_found',
          );
        }
        for (var i = 0; i < copies; i++) {
          final ok = await Printing.directPrintPdf(
            printer: printer.first,
            onLayout: (_) async => pdf,
            name: name,
          );
          if (!ok) throw PrinterException('"${printer.first.name}" did not accept the job.');
        }
        return true;
      case PrinterConnection.bluetooth:
      case PrinterConnection.usb:
      case PrinterConnection.network:
        final image = await rasterizePdf(pdf, config.dotsPerLine);
        await printMonoImage(config, image, name: name, copies: copies, openDrawer: openDrawer);
        return true;
    }
  }

  /// Prints a Flutter image, scaled to the paper's width. Draw a widget into
  /// one with `RenderRepaintBoundary.toImage`: text is then shaped by Flutter,
  /// so every script prints correctly.
  ///
  /// Driver printers and the system dialog get it as a one-page PDF.
  Future<bool> printImage(
    PrinterConfig config,
    ui.Image image, {
    String name = 'Receipt',
    int copies = 1,
    bool openDrawer = false,
    int threshold = 160,
  }) async {
    _checkReady(config);
    if (!config.isRaw) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final width = config.printableWidthMm * PdfPageFormat.mm;
      final doc = pw.Document()
        ..addPage(
          pw.Page(
            pageFormat: PdfPageFormat(width, width * image.height / image.width, marginAll: 0),
            build: (_) => pw.Image(pw.MemoryImage(png!.buffer.asUint8List()), fit: pw.BoxFit.fill),
          ),
        );
      return printPdf(config, await doc.save(), name: name, copies: copies);
    }
    final mono = await rasterizeImage(image, config.dotsPerLine, threshold: threshold);
    await printMonoImage(config, mono, name: name, copies: copies, openDrawer: openDrawer);
    return true;
  }

  /// Sends a black-and-white image to a raw printer, with the feed, cut and
  /// drawer commands of its language.
  Future<void> printMonoImage(
    PrinterConfig config,
    MonoImage image, {
    String name = 'Receipt',
    int copies = 1,
    bool openDrawer = false,
  }) {
    return sendRaw(
      config,
      PrinterCommands.receipt(
        image,
        config.language,
        copies: copies,
        openDrawer: openDrawer,
        extraFeedMm: config.extraFeedMm,
      ),
      name: name,
    );
  }

  /// Opens the cash drawer wired to a raw printer.
  Future<void> openCashDrawer(PrinterConfig config) =>
      sendRaw(config, PrinterCommands.drawer(config.language), name: 'Cash drawer');

  /// Sends ready-made printer commands to a Bluetooth, USB or network
  /// printer. [name] is the spooler job name on Windows.
  Future<void> sendRaw(PrinterConfig config, List<int> bytes, {String name = 'Receipt'}) {
    _checkReady(config);
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return switch (config.connection) {
      PrinterConnection.bluetooth => devices.sendBluetooth(config.deviceId!, data),
      PrinterConnection.usb => devices.sendUsb(config.deviceId!, data, documentName: name),
      PrinterConnection.network => devices.sendNetwork(config.host.trim(), config.port, data),
      _ => throw const PrinterException(
        'Only Bluetooth, USB and network printers take raw commands.',
        code: 'unsupported',
      ),
    };
  }

  /// Renders every page of [pdf] at 203 dpi (8 dots/mm), black and white,
  /// [dots] wide, one below the other.
  static Future<MonoImage> rasterizePdf(Uint8List pdf, int dots, {int threshold = 160}) async {
    final pages = <MonoImage>[];
    await for (final page in Printing.raster(pdf, dpi: 203.2)) {
      pages.add(await compute(_toMono, (page.pixels, page.width, page.height, dots, threshold)));
    }
    if (pages.isEmpty) throw const PrinterException('The document has no pages to print.');
    return MonoImage.stack(pages);
  }

  /// Scales [image] to [dots] wide and makes it black and white.
  static Future<MonoImage> rasterizeImage(ui.Image image, int dots, {int threshold = 160}) async {
    var source = image;
    if (image.width != dots) {
      final height = (image.height * dots / image.width).round();
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, dots.toDouble(), height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      source = await recorder.endRecording().toImage(dots, height);
    }
    try {
      final rgba = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) throw const PrinterException('The image could not be read.');
      return await compute(_toMono, (
        rgba.buffer.asUint8List(),
        source.width,
        source.height,
        dots,
        threshold,
      ));
    } finally {
      if (!identical(source, image)) source.dispose();
    }
  }

  static void _checkReady(PrinterConfig config) {
    if (!config.isReady) {
      throw const PrinterException('Choose a printer first.', code: 'not_ready');
    }
  }
}

MonoImage _toMono((Uint8List, int, int, int, int) args) {
  final (rgba, width, height, dots, threshold) = args;
  return MonoImage.fromRgba(rgba, width, height, targetWidth: dots, threshold: threshold);
}
