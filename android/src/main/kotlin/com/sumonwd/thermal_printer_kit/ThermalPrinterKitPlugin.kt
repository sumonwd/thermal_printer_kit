package com.sumonwd.thermal_printer_kit

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

/**
 * Bluetooth (Classic and LE) and USB OTG receipt printers for the Dart
 * `PrinterDevices` class, on the `thermal_printer_kit` channel. The activity is
 * needed only to ask for permissions.
 */
class ThermalPrinterKitPlugin : FlutterPlugin, ActivityAware {
    private var channel: MethodChannel? = null
    private var printers: PrinterDevices? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val devices = PrinterDevices(binding.applicationContext)
        printers = devices
        channel = MethodChannel(binding.binaryMessenger, "thermal_printer_kit").also {
            it.setMethodCallHandler(devices)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        printers?.dispose()
        printers = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() = detach()

    private fun attach(binding: ActivityPluginBinding) {
        val devices = printers ?: return
        activityBinding = binding
        devices.activity = binding.activity
        binding.addRequestPermissionsResultListener(devices)
    }

    private fun detach() {
        printers?.let { activityBinding?.removeRequestPermissionsResultListener(it) }
        printers?.activity = null
        activityBinding = null
    }
}
