import Flutter
import UIKit

/// Bluetooth LE receipt printers for the Dart `PrinterDevices` class, on the
/// `thermal_printer_kit` channel. iOS has no Bluetooth Classic or USB printing
/// for apps, so those methods answer "not implemented".
public final class ThermalPrinterKitPlugin: NSObject, FlutterPlugin {
  private let printers = BlePrinters()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "thermal_printer_kit", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ThermalPrinterKitPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    printers.handle(call, result: result)
  }
}
