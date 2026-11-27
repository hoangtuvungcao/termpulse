package com.termpulse.termpulse

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/** USB Host driver bridge. Permission is requested by Android for each device. */
class UsbSerialBridge(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val app = context.applicationContext
    private val manager = app.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val methods = MethodChannel(messenger, "termpulse/android_serial")
    private val events = EventChannel(messenger, "termpulse/android_serial/events")
    private val permissionAction = "${app.packageName}.USB_PERMISSION.${UUID.randomUUID()}"
    private var sink: EventChannel.EventSink? = null
    @Volatile private var disposed = false

    // Accessed on the main thread; USB I/O itself runs on worker/driver threads.
    private data class Session(val port: UsbSerialPort, val io: SerialInputOutputManager)
    private data class Pending(val call: MethodCall, val result: MethodChannel.Result, val deviceId: Int)
    private val sessions = mutableMapOf<String, Session>()
    private val pending = mutableMapOf<String, Pending>()
    private val opening = mutableMapOf<String, String>()
    private val cancelled = mutableSetOf<String>()

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (disposed) return
            @Suppress("DEPRECATION")
            val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
            when (intent.action) {
                permissionAction -> {
                    val requests = pending.filterValues { it.deviceId == device.deviceId }.toMap()
                    for ((id, request) in requests) {
                        pending.remove(id)
                        if (manager.hasPermission(device) &&
                            intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                            openGranted(request.call, request.result)
                        } else {
                            request.result.error("permission_denied", "Quyền truy cập USB Serial bị từ chối.", null)
                        }
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    for ((id, name) in opening) {
                        if (name.startsWith("usb:${device.deviceName}:")) cancelled.add(id)
                    }
                    val requests = pending.filterValues { it.deviceId == device.deviceId }.toMap()
                    for ((id, request) in requests) {
                        pending.remove(id)
                        request.result.error("device_detached", "Thiết bị USB Serial đã ngắt kết nối.", null)
                    }
                    for ((id, session) in sessions.toMap()) {
                        if (session.port.device.deviceId == device.deviceId) {
                            failSession(id, "Thiết bị USB Serial đã ngắt kết nối.")
                        }
                    }
                }
            }
        }
    }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        val filter = IntentFilter(permissionAction).apply {
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            app.registerReceiver(receiver, filter)
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        closeAll()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("bridge_closed", "Kết nối USB Serial đã đóng.", null)
            return
        }
        try {
            when (call.method) {
                "listPorts" -> result.success(listPorts())
                "open" -> requestOpen(call, result)
                "start" -> {
                    val id = call.argument<String>("sessionId")!!
                    val session = sessions[id] ?: throw IllegalStateException("Không tìm thấy phiên USB Serial.")
                    worker.execute {
                        try {
                            session.io.start()
                            main.post { result.success(null) }
                        } catch (error: Exception) {
                            main.post {
                                failSession(id, "Lỗi USB Serial: ${error.message}")
                                result.error("start_failed", "Lỗi USB Serial: ${error.message}", null)
                            }
                        }
                    }
                }
                "write" -> {
                    val id = call.argument<String>("sessionId")!!
                    val bytes = call.argument<ByteArray>("bytes")!!
                    val session = sessions[id] ?: throw IllegalStateException("Không tìm thấy phiên USB Serial.")
                    worker.execute {
                        try {
                            session.port.write(bytes, 5000)
                            main.post { result.success(null) }
                        } catch (error: Exception) {
                            main.post {
                                failSession(id, "Lỗi USB Serial: ${error.message}")
                                result.error("write_failed", "Lỗi USB Serial: ${error.message}", null)
                            }
                        }
                    }
                }
                "close" -> {
                    closeSession(call.argument<String>("sessionId")!!)
                    result.success(null)
                }
                "closeAll" -> {
                    closeAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("usb_serial", error.message, null)
        }
    }

    private fun portName(port: UsbSerialPort) =
        "usb:${port.device.deviceName}:${port.portNumber}"

    private fun findPort(name: String): UsbSerialPort? =
        UsbSerialProber.getDefaultProber().findAllDrivers(manager)
            .flatMap { it.ports }.firstOrNull { portName(it) == name }

    private fun listPorts(): List<Map<String, Any?>> =
        UsbSerialProber.getDefaultProber().findAllDrivers(manager).flatMap { driver ->
            driver.ports.map { port ->
                val device = driver.device
                val serial = if (manager.hasPermission(device)) {
                    runCatching { device.serialNumber }.getOrNull()
                } else null
                mapOf(
                    "portName" to portName(port),
                    "manufacturer" to device.manufacturerName,
                    "product" to "${device.productName ?: driver.javaClass.simpleName} · ${port.portNumber + 1}",
                    "serialNumber" to serial,
                )
            }
        }

    private fun requestOpen(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("sessionId")!!
        check(id !in sessions && id !in pending && id !in opening) { "Phiên USB Serial đã tồn tại." }
        val port = findPort(call.argument<String>("portName")!!)
            ?: throw IllegalArgumentException("Không tìm thấy cổng USB Serial. Hãy quét lại thiết bị.")
        check(sessions.values.none { portName(it.port) == portName(port) } &&
            pending.values.none { it.call.argument<String>("portName") == portName(port) } &&
            opening.values.none { it == portName(port) }) {
            "Cổng USB Serial đang được sử dụng."
        }
        if (manager.hasPermission(port.device)) {
            openGranted(call, result)
            return
        }
        pending[id] = Pending(call, result, port.device.deviceId)
        // USB Manager adds EXTRA_DEVICE/EXTRA_PERMISSION_GRANTED, requiring a
        // mutable PendingIntent on Android 12+. Limit delivery to this package.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val permission = PendingIntent.getBroadcast(
            app, port.device.deviceId, Intent(permissionAction).setPackage(app.packageName), flags)
        try {
            manager.requestPermission(port.device, permission)
        } catch (error: Exception) {
            pending.remove(id)
            result.error("permission_failed", "Không yêu cầu được quyền USB Serial: ${error.message}", null)
        }
    }

    private fun openGranted(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("sessionId")!!
        val name = call.argument<String>("portName")!!
        opening[id] = name
        worker.execute {
            var port: UsbSerialPort? = null
            try {
                port = findPort(name)
                    ?: throw IllegalArgumentException("Không tìm thấy cổng USB Serial. Hãy quét lại thiết bị.")
                val baud = call.argument<Int>("baudRate")!!
                val bits = call.argument<Int>("dataBits")!!
                val stops = call.argument<Int>("stopBits")!!
                require(baud in 1..4000000 && bits in 5..8 && stops in 1..2) {
                    "Thông số USB Serial không hợp lệ."
                }
                val parity = when (call.argument<String>("parity")) {
                    "none" -> UsbSerialPort.PARITY_NONE
                    "odd" -> UsbSerialPort.PARITY_ODD
                    "even" -> UsbSerialPort.PARITY_EVEN
                    else -> throw IllegalArgumentException("Parity USB Serial không hợp lệ.")
                }
                val flow = when (call.argument<String>("flowControl")) {
                    "none" -> UsbSerialPort.FlowControl.NONE
                    "hardware" -> UsbSerialPort.FlowControl.RTS_CTS
                    "software" -> UsbSerialPort.FlowControl.XON_XOFF
                    else -> throw IllegalArgumentException("Flow control USB Serial không hợp lệ.")
                }
                val connection = manager.openDevice(port.device)
                    ?: throw IllegalStateException("Không mở được thiết bị USB Serial. Kiểm tra quyền truy cập.")
                try {
                    port.open(connection)
                    port.setParameters(baud, bits, stops, parity)
                    require(port.supportedFlowControl.contains(flow)) {
                        "Thiết bị USB Serial không hỗ trợ flow control đã chọn."
                    }
                    port.setFlowControl(flow)
                    // CDC/ACM devices commonly require DTR before emitting data.
                    runCatching { port.dtr = true }
                    if (flow == UsbSerialPort.FlowControl.NONE) runCatching { port.rts = true }
                } catch (error: Exception) {
                    connection.close()
                    throw error
                }
                val io = SerialInputOutputManager(port, object : SerialInputOutputManager.Listener {
                    override fun onNewData(data: ByteArray) {
                        main.post {
                            if (id in sessions) sink?.success(mapOf(
                                "sessionId" to id, "kind" to "output_bytes", "bytes" to data))
                        }
                    }
                    override fun onRunError(error: Exception) {
                        main.post { failSession(id, "Lỗi USB Serial: ${error.message}") }
                    }
                })
                val opened = port
                main.post {
                    opening.remove(id)
                    if (disposed || cancelled.remove(id)) {
                        worker.execute { runCatching { opened.close() } }
                        result.error("cancelled", "Kết nối USB Serial đã hủy.", null)
                    } else {
                        sessions[id] = Session(opened, io)
                        result.success(null)
                    }
                    shutdownWhenIdle()
                }
            } catch (error: Exception) {
                runCatching { port?.close() }
                main.post {
                    opening.remove(id)
                    cancelled.remove(id)
                    result.error("open_failed", "Không mở được USB Serial: ${error.message}", null)
                    shutdownWhenIdle()
                }
            }
        }
    }

    private fun failSession(id: String, reason: String) {
        if (id !in sessions) return
        sink?.success(mapOf("sessionId" to id, "kind" to "error", "text" to reason))
        closeSession(id)
    }

    private fun closeSession(id: String) {
        pending.remove(id)?.result?.error("cancelled", "Kết nối USB Serial đã hủy.", null)
        if (id in opening) cancelled.add(id)
        val session = sessions.remove(id) ?: return
        // Close immediately on the worker so a blocked read is unblocked.
        session.io.listener = null
        session.io.stop()
        worker.execute { runCatching { session.port.close() } }
    }

    private fun closeAll() {
        for (id in (sessions.keys + pending.keys + opening.keys).toSet()) closeSession(id)
    }

    private fun shutdownWhenIdle() {
        // An in-flight open posts its result to main before it can be closed.
        // Keep the executor alive until that callback has queued its cleanup.
        if (disposed && opening.isEmpty()) worker.shutdown()
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        for (id in sessions.keys.toList()) failSession(id, "Kết nối USB Serial đã đóng.")
        closeAll()
        app.unregisterReceiver(receiver)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        shutdownWhenIdle()
    }
}
