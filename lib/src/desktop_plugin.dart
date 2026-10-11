/// Registers the package on Windows, macOS and Linux, where it needs no
/// native code: network printers use sockets, Windows USB printers the print
/// spooler (FFI), and driver printers the `printing` package.
class ThermalPrinterKitDesktop {
  /// Called by Flutter's plugin registrant. Nothing to set up.
  static void registerWith() {}
}
