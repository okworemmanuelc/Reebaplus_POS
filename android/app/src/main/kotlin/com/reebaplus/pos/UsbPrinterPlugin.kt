package com.reebaplus.pos

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * #614: USB receipt printers over Android's USB Host API. Our own code (no
 * GPL plugin). Dart side: lib/shared/services/usb_printer_channel.dart.
 *
 * Methods on [CHANNEL]:
 *  - list -> [{id, name, vendorId, productId, hasPermission}]
 *  - requestPermission(id) -> bool
 *  - write(id, bytes) -> bool (true only when every chunk fully transferred)
 *
 * Every failure answers false / an empty list; nothing here may crash the app.
 */
class UsbPrinterPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "reebaplus/usb_printer"
        private const val TAG = "UsbPrinterPlugin"
        private const val ACTION_USB_PERMISSION = "com.reebaplus.pos.USB_PERMISSION"
        private const val CHUNK_BYTES = 16 * 1024
        private const val CHUNK_TIMEOUT_MS = 5000
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val usbManager: UsbManager? =
        context.getSystemService(Context.USB_SERVICE) as? UsbManager

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> runIo(result, emptyList<Map<String, Any?>>()) { listPrinters() }
            "requestPermission" -> requestPermission(call.argument<String>("id"), result)
            "write" -> {
                val id = call.argument<String>("id")
                val bytes = call.argument<ByteArray>("bytes")
                runIo(result, false) { write(id, bytes) }
            }
            else -> result.notImplemented()
        }
    }

    /** Runs [block] off the main thread and answers on the main thread. */
    private fun <T> runIo(result: MethodChannel.Result, fallback: T, block: () -> T) {
        try {
            io.execute {
                val value = try {
                    block()
                } catch (t: Throwable) {
                    Log.e(TAG, "USB printer call failed", t)
                    fallback
                }
                mainHandler.post { result.success(value) }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "USB printer executor rejected the call", t)
            result.success(fallback)
        }
    }

    // ── list ────────────────────────────────────────────────────────────────

    private fun listPrinters(): List<Map<String, Any?>> {
        val manager = usbManager ?: return emptyList()
        val devices = manager.deviceList.values.toList()
        var printers = devices.filter { hasPrinterInterface(it) }
        if (printers.isEmpty()) {
            // Some cheap printers report a vendor-specific interface instead
            // of class 7; accept those that expose a bulk-OUT endpoint.
            printers = devices.filter { findVendorBulkOutInterface(it) != null }
        }
        return printers.map { d ->
            mapOf(
                "id" to idFor(d),
                "name" to nameFor(d),
                "vendorId" to d.vendorId,
                "productId" to d.productId,
                "hasPermission" to manager.hasPermission(d),
            )
        }
    }

    private fun hasPrinterInterface(device: UsbDevice): Boolean =
        (0 until device.interfaceCount).any {
            device.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_PRINTER
        }

    private fun findVendorBulkOutInterface(device: UsbDevice): UsbInterface? =
        (0 until device.interfaceCount)
            .map { device.getInterface(it) }
            .firstOrNull {
                it.interfaceClass == UsbConstants.USB_CLASS_VENDOR_SPEC &&
                    bulkOut(it) != null
            }

    private fun idFor(device: UsbDevice): String {
        val base = "usb:${device.vendorId}:${device.productId}"
        // The serial is only readable without USB permission before API 29
        // (it throws SecurityException after). Using it only there keeps the
        // id the same before and after permission is granted, so the paper
        // size / print style saved under it are never orphaned.
        val serial = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            try {
                device.serialNumber
            } catch (_: Throwable) {
                null
            }
        } else {
            null
        }
        return if (serial.isNullOrBlank()) base else "$base:$serial"
    }

    private fun nameFor(device: UsbDevice): String {
        val product = device.productName?.trim()
        if (!product.isNullOrEmpty()) return product
        val maker = device.manufacturerName?.trim()
        if (!maker.isNullOrEmpty()) return maker
        return "USB printer"
    }

    /** Matches the full id first, then vendor:product alone. */
    private fun findDevice(id: String?): UsbDevice? {
        val manager = usbManager ?: return null
        if (id == null) return null
        val devices = manager.deviceList.values
        devices.firstOrNull { idFor(it) == id }?.let { return it }
        val parts = id.split(":")
        if (parts.size < 3 || parts[0] != "usb") return null
        val vid = parts[1].toIntOrNull() ?: return null
        val pid = parts[2].toIntOrNull() ?: return null
        return devices.firstOrNull { it.vendorId == vid && it.productId == pid }
    }

    // ── requestPermission ───────────────────────────────────────────────────

    private fun requestPermission(id: String?, result: MethodChannel.Result) {
        try {
            val manager = usbManager
            val device = findDevice(id)
            if (manager == null || device == null) {
                result.success(false)
                return
            }
            if (manager.hasPermission(device)) {
                result.success(true)
                return
            }
            var answered = false
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    if (intent.action != ACTION_USB_PERMISSION) return
                    try {
                        ctx.unregisterReceiver(this)
                    } catch (_: Throwable) {
                    }
                    if (answered) return
                    answered = true
                    val granted =
                        intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    result.success(granted || manager.hasPermission(device))
                }
            }
            val filter = IntentFilter(ACTION_USB_PERMISSION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
            // The system fills EXTRA_DEVICE / EXTRA_PERMISSION_GRANTED, so the
            // PendingIntent must be mutable on API 31+. Explicit package keeps
            // the broadcast inside the app.
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
            val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
            val pending = PendingIntent.getBroadcast(context, 0, intent, flags)
            manager.requestPermission(device, pending)
        } catch (t: Throwable) {
            Log.e(TAG, "USB permission request failed", t)
            result.success(false)
        }
    }

    // ── write ───────────────────────────────────────────────────────────────

    private fun write(id: String?, bytes: ByteArray?): Boolean {
        val manager = usbManager ?: return false
        if (bytes == null) return false
        val device = findDevice(id) ?: return false
        if (!manager.hasPermission(device)) return false

        val iface = printerInterface(device) ?: return false
        val endpoint = bulkOut(iface) ?: return false
        val connection = manager.openDevice(device) ?: return false
        try {
            if (!connection.claimInterface(iface, true)) return false
            try {
                val chunkSize = chunkSizeFor(endpoint)
                var offset = 0
                while (offset < bytes.size) {
                    val length = minOf(chunkSize, bytes.size - offset)
                    val sent = connection.bulkTransfer(
                        endpoint, bytes, offset, length, CHUNK_TIMEOUT_MS,
                    )
                    if (sent <= 0) {
                        Log.e(TAG, "bulkTransfer failed at $offset (sent=$sent)")
                        return false
                    }
                    // A short transfer is not fatal: send the rest next loop.
                    offset += sent
                }
                return true
            } finally {
                connection.releaseInterface(iface)
            }
        } finally {
            connection.close()
        }
    }

    private fun printerInterface(device: UsbDevice): UsbInterface? {
        val all = (0 until device.interfaceCount).map { device.getInterface(it) }
        return all.firstOrNull {
            it.interfaceClass == UsbConstants.USB_CLASS_PRINTER && bulkOut(it) != null
        } ?: findVendorBulkOutInterface(device)
            ?: all.firstOrNull { bulkOut(it) != null }
    }

    private fun bulkOut(iface: UsbInterface): UsbEndpoint? =
        (0 until iface.endpointCount)
            .map { iface.getEndpoint(it) }
            .firstOrNull {
                it.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                    it.direction == UsbConstants.USB_DIR_OUT
            }

    /** A whole number of packets, close to 16 KB. */
    private fun chunkSizeFor(endpoint: UsbEndpoint): Int {
        val packet = endpoint.maxPacketSize.takeIf { it > 0 } ?: 64
        return maxOf(packet, (CHUNK_BYTES / packet) * packet)
    }
}
