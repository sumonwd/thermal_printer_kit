package com.sumonwd.thermal_printer_kit

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Receipt printers over Bluetooth Classic (SPP), Bluetooth LE (BlePrinters) and
 * USB OTG. Dart sends ready-made printer commands (ESC/POS or Star), so this
 * only finds printers and moves bytes.
 *
 * Classic printers must be paired in Android's Bluetooth settings first; BLE
 * printers are found by scanning. Android 12+ asks for "Nearby devices"
 * (BLUETOOTH_CONNECT and BLUETOOTH_SCAN); Android 11 and older need the location
 * permission to scan, without which only paired printers are listed.
 */
class PrinterDevices(private val context: Context) :
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {
    companion object {
        const val PERMISSION_REQUEST = 7301
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private const val CHUNK = 4096
        private const val NEARBY_DEVICES = "Allow \"Nearby devices\" for this app to use Bluetooth printers."
    }

    /** The current activity, to ask for permissions; set by the plugin. */
    var activity: Activity? = null

    private val main = Handler(Looper.getMainLooper())

    // One job at a time: printers don't like two connections at once
    private val worker = Executors.newSingleThreadExecutor()
    private var pendingPermission: MethodChannel.Result? = null
    private val ble by lazy { BlePrinters(context) }
    private val usbPermissionAction get() = "${context.packageName}.thermal_printer_kit.USB_PERMISSION"

    fun dispose() {
        worker.shutdown()
        pendingPermission?.success(false)
        pendingPermission = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "bluetoothPermission" -> requestBluetoothPermission(result)
                "bluetoothDevices" -> result.success(bluetoothDevices())
                "openBluetoothSettings" -> {
                    val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                    val current = activity
                    if (current != null) {
                        current.startActivity(intent)
                    } else {
                        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    result.success(null)
                }
                "bluetoothSend" -> background(result) {
                    bluetoothSend(call.argument<String>("address")!!, call.argument<ByteArray>("bytes")!!)
                }
                "bleScan" -> backgroundValue(result) {
                    val adapter = enabledAdapter()
                    when {
                        adapter == null -> mapOf("enabled" to false, "devices" to emptyList<Any>())
                        !canScan() -> mapOf("enabled" to true, "devices" to emptyList<Any>())
                        else -> mapOf(
                            "enabled" to true,
                            "devices" to ble.scan(adapter, (call.argument<Int>("seconds") ?: 4).toLong()),
                        )
                    }
                }
                "bleSend" -> background(result) {
                    val adapter = enabledAdapter() ?: throw IOException("Bluetooth is off. Turn it on to print.")
                    ble.send(adapter, call.argument<String>("id")!!, call.argument<ByteArray>("bytes")!!)
                }
                "usbDevices" -> result.success(usbDevices())
                "usbSend" -> background(result) {
                    usbSend(
                        call.argument<Int>("vendorId")!!,
                        call.argument<Int>("productId")!!,
                        call.argument<ByteArray>("bytes")!!,
                    )
                }
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("permission", NEARBY_DEVICES, null)
        } catch (e: Exception) {
            result.error("printer", e.message ?: "The printer could not be reached.", null)
        }
    }

    private fun background(result: MethodChannel.Result, job: () -> Unit) = backgroundValue(result) {
        job()
        null
    }

    private fun backgroundValue(result: MethodChannel.Result, job: () -> Any?) {
        worker.execute {
            try {
                val value = job()
                main.post { result.success(value) }
            } catch (e: SecurityException) {
                main.post { result.error("permission", NEARBY_DEVICES, null) }
            } catch (e: Exception) {
                main.post { result.error("printer", e.message ?: "The printer could not be reached.", null) }
            }
        }
    }

    // ---------------------------------------------------------------- Bluetooth

    private fun granted(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun hasBluetoothPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || granted(Manifest.permission.BLUETOOTH_CONNECT)

    /** Scanning for BLE printers: "Nearby devices" (Android 12+) or location (Android 11 and older). */
    private fun scanPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Manifest.permission.BLUETOOTH_SCAN
        else Manifest.permission.ACCESS_FINE_LOCATION

    private fun canScan(): Boolean = granted(scanPermission())

    /** Asks for what Bluetooth printing needs; true when paired printers can be used. */
    private fun requestBluetoothPermission(result: MethodChannel.Result) {
        val missing = listOfNotNull(
            Manifest.permission.BLUETOOTH_CONNECT.takeIf {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !hasBluetoothPermission()
            },
            scanPermission().takeIf { !canScan() },
        )
        val current = activity
        if (missing.isEmpty() || current == null) {
            result.success(hasBluetoothPermission())
            return
        }
        pendingPermission?.success(hasBluetoothPermission())
        pendingPermission = result
        current.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        // Scanning is optional: without it only paired printers are listed
        pendingPermission?.success(hasBluetoothPermission())
        pendingPermission = null
        return true
    }

    private fun adapter(): BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?)?.adapter

    private fun enabledAdapter(): BluetoothAdapter? = adapter()?.takeIf { it.isEnabled }

    @SuppressLint("MissingPermission")
    private fun bluetoothDevices(): Map<String, Any?> {
        val adapter = enabledAdapter() ?: return mapOf("enabled" to false, "devices" to emptyList<Any>())
        val devices = adapter.bondedDevices
            // SPP needs Bluetooth Classic; BLE-only devices can't take it
            .filter { it.type != BluetoothDevice.DEVICE_TYPE_LE }
            .map {
                mapOf(
                    "name" to (it.name ?: it.address),
                    "address" to it.address,
                    "isPrinter" to (it.bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.IMAGING),
                )
            }
        return mapOf("enabled" to true, "devices" to devices)
    }

    @SuppressLint("MissingPermission")
    private fun bluetoothSend(address: String, bytes: ByteArray) {
        val adapter = adapter() ?: throw IOException("This device has no Bluetooth.")
        if (!adapter.isEnabled) throw IOException("Bluetooth is off. Turn it on to print.")
        val device = adapter.getRemoteDevice(address)

        var socket: BluetoothSocket = device.createRfcommSocketToServiceRecord(SPP_UUID)
        try {
            try {
                socket.connect()
            } catch (e: IOException) {
                // Some cheap printers only accept an unencrypted connection
                socket.close()
                socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                try {
                    socket.connect()
                } catch (e2: IOException) {
                    throw IOException("Could not connect to ${device.name ?: address}. Is it on and in range?")
                }
            }
            val out = socket.outputStream
            var offset = 0
            while (offset < bytes.size) {
                val length = minOf(CHUNK, bytes.size - offset)
                out.write(bytes, offset, length)
                offset += length
            }
            out.flush()
            // Closing at once can drop the last buffer before it leaves the radio
            Thread.sleep(1500)
        } finally {
            try {
                socket.close()
            } catch (_: IOException) {
            }
        }
    }

    // ---------------------------------------------------------------- USB

    private val usbManager: UsbManager get() = context.getSystemService(Context.USB_SERVICE) as UsbManager

    /** The interface and bulk OUT endpoint to print on: a printer-class interface if there is one. */
    private fun printerEndpoint(device: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        val candidates = (0 until device.interfaceCount).map { device.getInterface(it) }
            .sortedBy { if (it.interfaceClass == UsbConstants.USB_CLASS_PRINTER) 0 else 1 }
        for (iface in candidates) {
            for (i in 0 until iface.endpointCount) {
                val ep = iface.getEndpoint(i)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == UsbConstants.USB_DIR_OUT) {
                    return iface to ep
                }
            }
        }
        return null
    }

    private fun usbDevices(): List<Map<String, Any?>> = usbManager.deviceList.values.mapNotNull { device ->
        val (iface, _) = printerEndpoint(device) ?: return@mapNotNull null
        val name = try {
            listOfNotNull(device.manufacturerName, device.productName).joinToString(" ").ifBlank { null }
        } catch (_: SecurityException) {
            null
        }
        mapOf(
            "vendorId" to device.vendorId,
            "productId" to device.productId,
            "name" to (name ?: "USB printer %04X:%04X".format(device.vendorId, device.productId)),
            "isPrinter" to (iface.interfaceClass == UsbConstants.USB_CLASS_PRINTER),
        )
    }

    private fun usbSend(vendorId: Int, productId: Int, bytes: ByteArray) {
        val device = usbManager.deviceList.values.firstOrNull { it.vendorId == vendorId && it.productId == productId }
            ?: throw IOException("The USB printer is not connected.")
        if (!usbManager.hasPermission(device) && !requestUsbPermission(device)) {
            throw IOException("USB access to the printer was not allowed.")
        }
        val (iface, endpoint) = printerEndpoint(device) ?: throw IOException("This USB device can't print.")
        val connection = usbManager.openDevice(device) ?: throw IOException("Could not open the USB printer.")
        try {
            if (!connection.claimInterface(iface, true)) throw IOException("The USB printer is busy.")
            var offset = 0
            while (offset < bytes.size) {
                val length = minOf(16384, bytes.size - offset)
                val sent = connection.bulkTransfer(endpoint, bytes, offset, length, 10000)
                if (sent <= 0) throw IOException("The USB printer stopped responding.")
                offset += sent
            }
            connection.releaseInterface(iface)
        } finally {
            connection.close()
        }
    }

    /** Shows Android's "Allow access to the USB device" prompt and waits for the answer. */
    private fun requestUsbPermission(device: UsbDevice): Boolean {
        val latch = CountDownLatch(1)
        var granted = false
        val action = usbPermissionAction
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                if (intent.action != action) return
                granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                latch.countDown()
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        try {
            // Mutable so the system can add EXTRA_PERMISSION_GRANTED; explicit, as Android 14 requires
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val intent = PendingIntent.getBroadcast(context, 0, Intent(action).setPackage(context.packageName), flags)
            main.post { usbManager.requestPermission(device, intent) }
            latch.await(60, TimeUnit.SECONDS)
        } finally {
            context.unregisterReceiver(receiver)
        }
        return granted && usbManager.hasPermission(device)
    }
}
