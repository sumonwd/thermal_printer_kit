# thermal_printer_kit

Print receipts on thermal printers from Flutter, over every common connection, with one API:

| Connection | Android | iOS | Windows | macOS | Linux |
|---|:-:|:-:|:-:|:-:|:-:|
| Bluetooth Classic (SPP, paired printers) | ✅ | ❌ (Apple allows no Classic printers) | ❌ | ❌ | ❌ |
| Bluetooth LE | ✅ | ✅ | ❌ | ❌ | ❌ |
| USB | ✅ (OTG) | ❌ | ✅ (installed printer, RAW job) | ❌ | ❌ |
| Network (Wi-Fi / LAN, raw TCP port 9100) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Installed printer driver, no dialog | ❌ | ❌ | ✅ | ✅ | ✅ |
| System print dialog | ✅ | ✅ | ✅ | ✅ | ✅ |

- **Printer languages:** ESC/POS (Epson, Xprinter, Rongta, Sunmi, HPRT and most others), Star Line /
  Star Graphic (TSP100/TSP143, TSP650II, TSP700II, TSP800II, SP700) and StarPRNT (mC-Print2/3, mPOP,
  SM-L200/L300, SM-S, SM-T). The language is guessed from the printer's name.
- **Jobs are images.** Lay out a receipt as a PDF (with the [`pdf`](https://pub.dev/packages/pdf)
  package) or draw it with Flutter, and it prints exactly as drawn: any font, any language, logos,
  QR codes and barcodes. No code pages.
- **Paper:** 58 mm and 80 mm rolls, 203 dpi and narrower 180 dpi heads, extra feed before the cut.
- **Cash drawer** kick on all three printer languages.
- **Discovery:** paired and nearby Bluetooth printers, USB printers, driver printers, and a scan of
  the local network for printers on port 9100.
- Errors are thrown as `PrinterException`, with messages written to be shown to users.

## Install

```sh
flutter pub add thermal_printer_kit
```

### Android

Nothing to do: the plugin's manifest adds the Bluetooth permissions (`BLUETOOTH_CONNECT` and
`BLUETOOTH_SCAN` with `neverForLocation` on Android 12+, `ACCESS_FINE_LOCATION` up to Android 11 for
Bluetooth LE scanning), `INTERNET`, and optional Bluetooth / USB host features.

If you don't use Bluetooth LE printers on Android 11 and older, you can drop the location
permission in your app's `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
    tools:node="remove"/>
```

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Prints receipts on your Bluetooth printer.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Prints receipts on printers on your local network.</string>
```

### macOS

Allow network access (network printers) and printing in
`macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.print</key>
<true/>
```

### Windows, Linux

Nothing to do.

## Usage

```dart
import 'package:thermal_printer_kit/thermal_printer_kit.dart';
import 'package:pdf/widgets.dart' as pw;

final printer = ThermalPrinter();

// 1. Find a printer
final scan = await printer.devices.bluetoothDevices(); // or usbDevices(), driverPrinters(),
final device = scan.devices.first;                     // scanNetwork() (a Stream)

// 2. Make a config: connection, device, language, paper. Save config.toJson() to remember it.
var config = device.applyTo(const PrinterConfig(paperWidth: PaperWidth.mm80));
// Network printer by address:
// config = const PrinterConfig(connection: PrinterConnection.network, host: '192.168.1.50');

// 3. Lay out the receipt on config.pageFormat (as wide as the printable area) and print it
final doc = pw.Document()
  ..addPage(pw.Page(
    pageFormat: config.pageFormat,
    build: (_) => pw.Column(children: [pw.Text('Hello, printer')]),
  ));
await printer.printPdf(config, await doc.save(), copies: 1, openDrawer: true);
```

### Print a Flutter widget

Draw any widget with a `RepaintBoundary`, then print the image. Text is shaped by Flutter, so
complex scripts (Bengali, Arabic, Thai, Devanagari, ...) print correctly.

```dart
final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
final image = await boundary.toImage(pixelRatio: 2);
await printer.printImage(config, image); // scaled to the paper's width
```

### Other calls

```dart
await printer.openCashDrawer(config);                 // raw printers only
await printer.sendRaw(config, [0x1B, 0x40]);          // your own command bytes
final image = await ThermalPrinter.rasterizePdf(pdf, config.dotsPerLine);
final bytes = PrinterCommands.receipt(image, PrinterLanguage.escPos, copies: 2);
```

Handle failures:

```dart
try {
  await printer.printPdf(config, pdf);
} on PrinterException catch (e) {
  showMessage(e.message); // e.code: permission, unsupported, not_ready, not_found or printer
}
```

## How it works

Bluetooth, USB and network printers get the job rasterised at 203 dpi (8 dots per mm), made 1-bit,
and sent as raster image commands in strips, followed by a feed and partial cut:

- ESC/POS: `GS v 0` images, `ESC J` feed, `GS V 66 0` cut, `ESC p` drawer.
- Star Line: raster mode (`ESC * r A`), continuous paper and feed-to-cutter set in the job (so the
  printer's page-length setting can't add a blank feed), `b n1 n2` rows with trailing white trimmed,
  `ESC FF EOT`, drawer `ESC * r D`.
- StarPRNT: `ESC GS S 1` images, `ESC J` feed, `ESC d 3` cut, `ESC BEL` + `BEL` drawer.

Bluetooth LE printers get the bytes on their writable characteristic (common printer services such
as `18F0/2AF1` first) in MTU-sized chunks. Windows USB printers get a RAW spooler job through
`winspool` (FFI), so the installed driver passes the commands through unchanged.

## License

MIT
