package app.brege.calls

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.messages.SmsRepository
import java.util.UUID
import uniffi.brege_ffi.CallActionKind
import uniffi.brege_ffi.CallData
import uniffi.brege_ffi.CallStatus

/**
 * Reports call state to the Mac and executes Answer / Decline / Hang up / Dial.
 * Call audio stays on the phone: macOS offers no hands-free audio path.
 */
object CallMonitor {
    private const val TAG = "BregeCalls"

    private lateinit var app: Context
    private var telephonyCallback: Any? = null
    private var phoneStateListener: PhoneStateListener? = null
    private var numberReceiver: BroadcastReceiver? = null

    private var current: CallData? = null
    private var lastState = TelephonyManager.CALL_STATE_IDLE
    /** Number of the last call started from the Mac, shown for outgoing calls. */
    private var lastDialled: String? = null

    fun init(context: Context) {
        app = context.applicationContext
    }

    private fun granted(p: String) = ContextCompat.checkSelfPermission(app, p) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    fun start() {
        if (telephonyCallback != null || phoneStateListener != null) return
        if (!granted(Manifest.permission.READ_PHONE_STATE)) return
        val tm = app.getSystemService(TelephonyManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 31) {
            val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) = onState(state, null)
            }
            tm.registerTelephonyCallback(ContextCompat.getMainExecutor(app), cb)
            telephonyCallback = cb
        } else {
            @Suppress("DEPRECATION")
            val listener = object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) = onState(state, phoneNumber)
            }
            @Suppress("DEPRECATION")
            tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            phoneStateListener = listener
        }
        // The incoming number is only delivered through this broadcast (needs READ_CALL_LOG).
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                @Suppress("DEPRECATION")
                val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                if (!number.isNullOrEmpty()) updateNumber(number)
            }
        }
        ContextCompat.registerReceiver(
            app, receiver, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED), ContextCompat.RECEIVER_EXPORTED,
        )
        numberReceiver = receiver
        UptimeLog.record("calls: monitoring call state")
    }

    fun stop() {
        val tm = app.getSystemService(TelephonyManager::class.java)
        if (Build.VERSION.SDK_INT >= 31) {
            (telephonyCallback as? TelephonyCallback)?.let { tm?.unregisterTelephonyCallback(it) }
        } else {
            @Suppress("DEPRECATION")
            phoneStateListener?.let { tm?.listen(it, PhoneStateListener.LISTEN_NONE) }
        }
        telephonyCallback = null
        phoneStateListener = null
        numberReceiver?.let { runCatching { app.unregisterReceiver(it) } }
        numberReceiver = null
    }

    private fun onState(state: Int, number: String?) {
        val previous = lastState
        lastState = state
        val now = System.currentTimeMillis()
        val call = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> newCall(incoming = true, CallStatus.RINGING, number, now)
            TelephonyManager.CALL_STATE_OFFHOOK -> when (previous) {
                TelephonyManager.CALL_STATE_RINGING -> current?.copy(status = CallStatus.ACTIVE, startedMs = now)
                else -> newCall(incoming = false, CallStatus.ACTIVE, lastDialled, now)
            }
            else -> current?.copy(status = CallStatus.ENDED).also { lastDialled = null }
        } ?: return
        current = if (call.status == CallStatus.ENDED) null else call
        publish(call)
    }

    private fun newCall(incoming: Boolean, status: CallStatus, number: String?, now: Long) = CallData(
        callId = UUID.randomUUID().toString(),
        status = status,
        number = number.orEmpty(),
        contactName = number?.let { SmsRepository(app).contactName(it) }.orEmpty(),
        incoming = incoming,
        startedMs = now,
    )

    private fun updateNumber(number: String) {
        val call = current ?: return
        if (call.number == number) return
        val updated = call.copy(number = number, contactName = SmsRepository(app).contactName(number))
        current = updated
        publish(updated)
    }

    private fun publish(call: CallData) {
        runCatching { Core.node?.publishCallState(call) }
        UptimeLog.record("calls: ${call.status.name.lowercase()} (${if (call.incoming) "incoming" else "outgoing"})")
    }

    // --- actions from the Mac -----------------------------------------------------------------

    @SuppressLint("MissingPermission")
    fun perform(action: CallActionKind, number: String, subId: Int) {
        val telecom = app.getSystemService(TelecomManager::class.java) ?: return
        try {
            when (action) {
                CallActionKind.ANSWER -> requirePermission(Manifest.permission.ANSWER_PHONE_CALLS) {
                    @Suppress("DEPRECATION")
                    telecom.acceptRingingCall()
                }
                CallActionKind.DECLINE, CallActionKind.HANG_UP -> requirePermission(Manifest.permission.ANSWER_PHONE_CALLS) {
                    @Suppress("DEPRECATION")
                    telecom.endCall()
                }
                CallActionKind.DIAL -> requirePermission(Manifest.permission.CALL_PHONE) {
                    lastDialled = number
                    val extras = Bundle()
                    if (subId >= 0 && Build.VERSION.SDK_INT >= 30) {
                        val tm = app.getSystemService(TelephonyManager::class.java)
                        telecom.callCapablePhoneAccounts.firstOrNull { tm?.getSubscriptionId(it) == subId }
                            ?.let { extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, it) }
                    }
                    telecom.placeCall(Uri.fromParts("tel", number, null), extras)
                }
            }
            UptimeLog.record("calls: performed ${action.name.lowercase()} from Mac")
        } catch (e: Exception) {
            Log.w(TAG, "call action failed", e)
            UptimeLog.record("calls: ${action.name.lowercase()} failed: ${e.javaClass.simpleName}")
        }
    }

    private inline fun requirePermission(permission: String, block: () -> Unit) {
        if (granted(permission)) block() else UptimeLog.record("calls: missing ${permission.substringAfterLast('.')}")
    }
}
