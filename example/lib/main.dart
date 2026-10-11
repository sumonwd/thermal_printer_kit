import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:thermal_printer_kit/thermal_printer_kit.dart';

void main() => runApp(const MaterialApp(home: PrinterDemo()));

/// Choose a printer, print a test receipt and open the cash drawer.
class PrinterDemo extends StatefulWidget {
  const PrinterDemo({super.key});

  @override
  State<PrinterDemo> createState() => _PrinterDemoState();
}

class _PrinterDemoState extends State<PrinterDemo> {
  final _printer = ThermalPrinter();
  final _host = TextEditingController();

  // Save `_config.toJson()` (e.g. with shared_preferences) to remember the printer
  PrinterConfig _config = const PrinterConfig();
  List<PrinterDevice> _devices = [];
  bool _busy = false;

  PrinterDevices get _discovery => _printer.devices;

  /// Lists the printers for the chosen connection.
  Future<void> _find() async {
    setState(() {
      _busy = true;
      _devices = [];
    });
    try {
      switch (_config.connection) {
        case PrinterConnection.bluetooth:
          final scan = await _discovery.bluetoothDevices();
          if (!scan.enabled) _show('Bluetooth is off.');
          _devices = scan.devices;
        case PrinterConnection.usb:
          _devices = await _discovery.usbDevices();
        case PrinterConnection.driver:
          _devices = await _discovery.driverPrinters();
        case PrinterConnection.network:
          await for (final device in _discovery.scanNetwork(
            port: _config.port,
          )) {
            setState(() => _devices = [..._devices, device]);
          }
        case PrinterConnection.system:
          break;
      }
      if (_devices.isEmpty && _config.connection != PrinterConnection.system) {
        _show('No printers found.');
      }
    } on PrinterException catch (e) {
      _show(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A small receipt as a roll-paper PDF.
  Future<Uint8List> _receipt() {
    final doc = pw.Document()
      ..addPage(
        pw.Page(
          pageFormat: _config.pageFormat,
          margin: const pw.EdgeInsets.all(8),
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(
                'thermal_printer_kit',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(_config.language.label, textAlign: pw.TextAlign.center),
              pw.Divider(),
              for (final (item, price) in [
                ('Coffee', '3.50'),
                ('Croissant', '2.25'),
              ])
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [pw.Text(item), pw.Text(price)],
                ),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Total',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                  pw.Text(
                    '5.75',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.BarcodeWidget(
                barcode: pw.Barcode.qrCode(),
                data: 'https://pub.dev',
                height: 80,
              ),
            ],
          ),
        ),
      );
    return doc.save();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } on PrinterException catch (e) {
      _show(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final connection = _config.connection;
    return Scaffold(
      appBar: AppBar(title: const Text('thermal_printer_kit')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<PrinterConnection>(
            initialValue: connection,
            decoration: const InputDecoration(labelText: 'Connection'),
            items: [
              for (final c in PrinterDevices.supportedConnections)
                DropdownMenuItem(value: c, child: Text(c.name)),
            ],
            onChanged: (c) => setState(() {
              _config = _config.copyWith(connection: c, clearDevice: true);
              _devices = [];
            }),
          ),
          if (_config.isRaw) ...[
            DropdownButtonFormField<PrinterLanguage>(
              initialValue: _config.language,
              decoration: const InputDecoration(labelText: 'Printer language'),
              items: [
                for (final l in PrinterLanguage.values)
                  DropdownMenuItem(value: l, child: Text(l.label)),
              ],
              onChanged: (l) =>
                  setState(() => _config = _config.copyWith(language: l)),
            ),
            SegmentedButton<PaperWidth>(
              segments: [
                for (final w in PaperWidth.values)
                  ButtonSegment(value: w, label: Text(w.label)),
              ],
              selected: {_config.paperWidth},
              onSelectionChanged: (s) => setState(
                () => _config = _config.copyWith(paperWidth: s.first),
              ),
            ),
          ],
          if (connection == PrinterConnection.network)
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'IP address',
                hintText: '192.168.1.50',
              ),
              onChanged: (v) =>
                  setState(() => _config = _config.copyWith(host: v.trim())),
            ),
          const SizedBox(height: 12),
          if (connection != PrinterConnection.system)
            OutlinedButton.icon(
              onPressed: _busy ? null : _find,
              icon: const Icon(Icons.search),
              label: const Text('Find printers'),
            ),
          RadioGroup<String>(
            groupValue: connection == PrinterConnection.network
                ? _config.host
                : _config.deviceId,
            onChanged: (id) => setState(() {
              _config = _devices.firstWhere((d) => d.id == id).applyTo(_config);
              _host.text = _config.host;
            }),
            child: Column(
              children: [
                for (final d in _devices)
                  RadioListTile<String>(
                    value: d.id,
                    title: Text(d.name),
                    subtitle: Text(
                      d.isPrinter ? d.id : '${d.id} (may not be a printer)',
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || !_config.isReady
                ? null
                : () => _run(() async {
                    final pdf = await _receipt();
                    await _printer.printPdf(_config, pdf, name: 'Test print');
                  }),
            icon: const Icon(Icons.print),
            label: const Text('Print test receipt'),
          ),
          if (_config.isRaw)
            TextButton(
              onPressed: _busy || !_config.isReady
                  ? null
                  : () => _run(() => _printer.openCashDrawer(_config)),
              child: const Text('Open cash drawer'),
            ),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            'Printable width: ${_config.printableWidthMm} mm '
            '(${_config.dotsPerLine} dots, ${PdfPageFormat.mm.toStringAsFixed(2)} pt/mm)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
