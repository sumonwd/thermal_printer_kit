package com.sumonwd.thermal_printer_kit

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Receipt printers over Bluetooth Low Energy (many current ESC/POS printers,
 * and the only Bluetooth printers iOS can use). The same job as Bluetooth
 * Classic: write ready-made printer commands to the printer's writable
 * characteristic, a chunk at a time. Runs on PrinterDevices' worker thread.
 */
class BlePrinters(private val context: Context) {
    companion object {
        /** Service / characteristic pairs of common BLE receipt printers, tried first. */
        private val KNOWN = listOf(
            "000018f0-0000-1000-8000-00805f9b34fb" to "00002af1-0000-1000-8000-00805f9b34fb",
            "e7810a71-73ae-499d-8c15-faa9aef0c3f2" to "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f",
            "49535343-fe7d-4ae5-8fa9-9fafd205e455" to "49535343-8841-43f4-a8d4-ecbe34729bb3",
            "0000ff00-0000-1000-8000-00805f9b34fb" to "0000ff02-0000-1000-8000-00805f9b34fb",
            "0000ffe0-0000-1000-8000-00805f9b34fb" to "0000ffe1-0000-1000-8000-00805f9b34fb",
        ).map { (s, c) -> UUID.fromString(s) to UUID.fromString(c) }

        /** Standard services that never take print data. */
        private val IGNORED = setOf("1800", "1801", "180a", "180f").map {
            UUID.fromString("0000$it-0000-1000-8000-00805f9b34fb")
        }

        private val PRINTER_NAMES = listOf("print", "pos", "tsp", "star", "mpt", "rpp", "xp-", "mtp", "bt-", "pt-")
    }

    /** BLE devices with a name seen nearby during [seconds]. */
    @SuppressLint("MissingPermission")
    fun scan(adapter: BluetoothAdapter, seconds: Long): List<Map<String, Any?>> {
        val scanner = adapter.bluetoothLeScanner ?: return emptyList()
        val found = ConcurrentHashMap<String, Map<String, Any?>>()
        val knownServices = KNOWN.map { ParcelUuid(it.first) }.toSet()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                // Unnamed devices (beacons, phones, ...) can't be told apart, so leave them out
                val name = result.scanRecord?.deviceName ?: result.device.name ?: return
                if (name.isBlank()) return
                val advertised = result.scanRecord?.serviceUuids.orEmpty()
                found[result.device.address] = mapOf(
                    "id" to result.device.address,
                    "name" to name,
                    "isPrinter" to (PRINTER_NAMES.any { name.lowercase().contains(it) } ||
                        advertised.any { it in knownServices }),
                )
            }
        }
        scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
        try {
            Thread.sleep(seconds * 1000)
        } finally {
            scanner.stopScan(callback)
        }
        return found.values.toList()
    }

    @SuppressLint("MissingPermission")
    fun send(adapter: BluetoothAdapter, address: String, bytes: ByteArray) {
        val device = adapter.getRemoteDevice(address)
        val name = device.name ?: "the printer"
        val link = Link()
        val gatt = device.connectGatt(context, false, link, BluetoothDevice.TRANSPORT_LE)
            ?: throw IOException("Could not connect to $name. Is it on and nearby?")
        try {
            if (!link.connected.await(15, TimeUnit.SECONDS) || !link.isConnected) {
                throw IOException("Could not connect to $name. Is it on and nearby?")
            }
            // A bigger MTU means fewer, larger chunks; not every printer agrees
            if (gatt.requestMtu(517)) link.mtuChanged.await(3, TimeUnit.SECONDS)
            if (!gatt.discoverServices() || !link.discovered.await(10, TimeUnit.SECONDS)) {
                throw IOException("$name did not answer.")
            }
            val characteristic = writableCharacteristic(gatt) ?: throw IOException("This Bluetooth device can't take print jobs.")
            val noResponse = characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
            val writeType = if (noResponse) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            val chunk = (link.mtu - 3).coerceIn(20, 512)

            var offset = 0
            while (offset < bytes.size) {
                if (!link.isConnected) throw IOException("The printer disconnected before the receipt was sent.")
                val end = minOf(offset + chunk, bytes.size)
                // Android reports every write, even without a response: wait for it before the next
                link.written = CountDownLatch(1)
                link.writeFailed = false
                if (!write(gatt, characteristic, bytes.copyOfRange(offset, end), writeType)) {
                    // The stack is still busy with the last chunk: try again shortly
                    Thread.sleep(20)
                    continue
                }
                if (!link.written.await(5, TimeUnit.SECONDS)) throw IOException("The printer stopped responding.")
                if (link.writeFailed) throw IOException("The printer refused the data.")
                offset = end
            }
            // Give the radio a moment to deliver the last chunks before hanging up
            Thread.sleep(1500)
        } finally {
            gatt.disconnect()
            gatt.close()
        }
    }

    private fun writableCharacteristic(gatt: BluetoothGatt): BluetoothGattCharacteristic? {
        val writable = BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
        for ((service, characteristic) in KNOWN) {
            val c = gatt.getService(service)?.getCharacteristic(characteristic)
            if (c != null && c.properties and writable != 0) return c
        }
        return gatt.services.filter { it.uuid !in IGNORED }
            .flatMap { it.characteristics }
            .firstOrNull { it.properties and writable != 0 }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun write(gatt: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, writeType: Int): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(c, value, writeType) == BluetoothGatt.GATT_SUCCESS
        } else {
            c.writeType = writeType
            c.value = value
            gatt.writeCharacteristic(c)
        }

    /** GATT callbacks turned into latches the worker thread can wait on. */
    private class Link : BluetoothGattCallback() {
        val connected = CountDownLatch(1)
        val mtuChanged = CountDownLatch(1)
        val discovered = CountDownLatch(1)

        @Volatile var written = CountDownLatch(1)
        @Volatile var writeFailed = false
        @Volatile var isConnected = false
        @Volatile var mtu = 23

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            isConnected = status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED
            connected.countDown()
            if (!isConnected) written.countDown()
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) this.mtu = mtu
            mtuChanged.countDown()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            discovered.countDown()
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            writeFailed = status != BluetoothGatt.GATT_SUCCESS
            written.countDown()
        }
    }
}
