package org.tetra.headset_ptt

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.database.ContentObserver
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID

/**
 * Bluetooth PTT headset (Savox BTH-101 and compatibles).
 *
 * PTT: the headset reports its PTT buttons as ASCII "+PTT=P" / "+PTT=R" on a
 * serial-port (SPP) RFCOMM channel that is not advertised in SDP, so we
 * connect to the channel number directly (hidden createRfcommSocket API) and
 * fall back to a regular SPP UUID lookup.
 *
 * Volume: HFP (AT+VGS) is owned by Android's own Bluetooth stack, which maps it
 * to the voice-call stream volume. We watch that volume and report it.
 *
 * Audio: [setScoRouting] sends voice audio to/from the headset over SCO.
 */
class HeadsetPttPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    @Volatile private var running = false
    @Volatile private var socket: BluetoothSocket? = null
    private var worker: Thread? = null
    private var volumeObserver: ContentObserver? = null
    private var lastVolume = -1

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        methods = MethodChannel(b.binaryMessenger, "org.tetra/headset_ptt")
        methods.setMethodCallHandler(this)
        events = EventChannel(b.binaryMessenger, "org.tetra/headset_ptt/events")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        stop()
        setScoRouting(false)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onListen(args: Any?, s: EventChannel.EventSink) { sink = s }
    override fun onCancel(args: Any?) { sink = null }

    private fun emit(m: Map<String, Any?>) = main.post { sink?.success(m) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                start(call.argument<String>("address") ?: "", call.argument<String>("namePrefix") ?: "Savox",
                    call.argument<Int>("channel") ?: 1)
                result.success(null)
            }
            "stop" -> { stop(); result.success(null) }
            "setScoRouting" -> result.success(setScoRouting(call.argument<Boolean>("on") ?: false))
            else -> result.notImplemented()
        }
    }

    // ───────── PTT over SPP ─────────

    private fun adapter(): BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    @SuppressLint("MissingPermission")
    private fun findDevice(a: BluetoothAdapter, address: String, namePrefix: String): BluetoothDevice? {
        if (address.isNotBlank()) return a.getRemoteDevice(address.trim().uppercase())
        return a.bondedDevices?.firstOrNull { (it.name ?: "").startsWith(namePrefix, ignoreCase = true) }
    }

    @SuppressLint("MissingPermission")
    private fun open(d: BluetoothDevice, channel: Int): BluetoothSocket {
        adapter()?.cancelDiscovery()
        // Undocumented but long-standing: the SPP service is not in SDP.
        try {
            val m = d.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
            val s = m.invoke(d, channel) as BluetoothSocket
            s.connect()
            return s
        } catch (e: Exception) {
            // fall through to the documented path
        }
        val s = d.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
        s.connect()
        return s
    }

    private fun start(address: String, namePrefix: String, channel: Int) {
        stop()
        running = true
        startVolumeWatch()
        worker = Thread({ loop(address, namePrefix, channel) }, "headset-ptt").also { it.start() }
    }

    private fun stop() {
        running = false
        try { socket?.close() } catch (_: IOException) {}
        socket = null
        worker?.interrupt()
        worker = null
        stopVolumeWatch()
    }

    @SuppressLint("MissingPermission")
    private fun loop(address: String, namePrefix: String, channel: Int) {
        var backoffMs = 1000L
        while (running) {
            var pressed = false
            try {
                val a = adapter() ?: throw IOException("No Bluetooth adapter")
                if (!a.isEnabled) throw IOException("Bluetooth is off")
                val d = findDevice(a, address, namePrefix) ?: throw IOException("No paired '$namePrefix' headset")
                emit(mapOf("type" to "state", "state" to "connecting", "detail" to (d.name ?: d.address)))
                val s = open(d, channel)
                socket = s
                emit(mapOf("type" to "state", "state" to "connected", "detail" to (d.name ?: d.address)))
                backoffMs = 1000L
                val input = s.inputStream
                val buf = ByteArray(256)
                val line = StringBuilder()
                while (running) {
                    val n = input.read(buf)
                    if (n < 0) throw IOException("Headset closed the link")
                    for (i in 0 until n) {
                        val c = buf[i].toInt().toChar()
                        if (c == '\r' || c == '\n') { line.setLength(0); continue }
                        line.append(c)
                        // No reliable terminator: act as soon as a full token is seen.
                        val t = line.toString()
                        if (t.endsWith("+PTT=P")) { pressed = true; emit(mapOf("type" to "ptt", "pressed" to true)); line.setLength(0) }
                        else if (t.endsWith("+PTT=R")) { pressed = false; emit(mapOf("type" to "ptt", "pressed" to false)); line.setLength(0) }
                        else if (line.length > 64) line.delete(0, line.length - 16)
                    }
                }
            } catch (e: Exception) {
                // Never leave the radio keyed if the link drops mid-transmission.
                if (pressed) emit(mapOf("type" to "ptt", "pressed" to false))
                try { socket?.close() } catch (_: IOException) {}
                socket = null
                if (!running) break
                emit(mapOf("type" to "state", "state" to "disconnected", "detail" to (e.message ?: e.javaClass.simpleName)))
                try { Thread.sleep(backoffMs) } catch (_: InterruptedException) { break }
                backoffMs = (backoffMs * 2).coerceAtMost(15000L)
            }
        }
        emit(mapOf("type" to "state", "state" to "stopped", "detail" to null))
    }

    // ───────── volume (HFP AT+VGS → voice-call stream) ─────────

    private fun audio() = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun reportVolume(force: Boolean) {
        val am = audio()
        val v = am.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
        if (force || v != lastVolume) {
            lastVolume = v
            emit(mapOf("type" to "volume", "level" to v, "max" to am.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)))
        }
    }

    private fun startVolumeWatch() {
        if (volumeObserver != null) return
        val o = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) = reportVolume(false)
        }
        context.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, o)
        volumeObserver = o
        lastVolume = -1
        main.post { reportVolume(true) }
    }

    private fun stopVolumeWatch() {
        volumeObserver?.let { context.contentResolver.unregisterContentObserver(it) }
        volumeObserver = null
    }

    // ───────── SCO audio routing ─────────

    @Suppress("DEPRECATION")
    private fun setScoRouting(on: Boolean): Boolean {
        val am = audio()
        return try {
            if (Build.VERSION.SDK_INT >= 31) {
                if (on) {
                    val dev = am.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                        ?: return false
                    am.mode = AudioManager.MODE_IN_COMMUNICATION
                    am.setCommunicationDevice(dev)
                } else {
                    am.clearCommunicationDevice()
                    am.mode = AudioManager.MODE_NORMAL
                    true
                }
            } else {
                if (on) {
                    am.mode = AudioManager.MODE_IN_COMMUNICATION
                    am.startBluetoothSco()
                    am.isBluetoothScoOn = true
                } else {
                    am.isBluetoothScoOn = false
                    am.stopBluetoothSco()
                    am.mode = AudioManager.MODE_NORMAL
                }
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    companion object {
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }
}
