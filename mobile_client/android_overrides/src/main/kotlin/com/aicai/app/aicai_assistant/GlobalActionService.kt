package com.aicai.app.aicai_assistant

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.view.accessibility.AccessibilityEvent
import android.util.Log
import android.os.Build
import androidx.annotation.RequiresApi

class GlobalActionService : AccessibilityService() {

    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == "com.aicai.app.PERFORM_GLOBAL_ACTION") {
                val actionId = intent.getIntExtra("actionId", 0)
                Log.d("GlobalActionService", "Received action request: $actionId")
                if (actionId > 0) {
                    performGlobalAction(actionId)
                }
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d("GlobalActionService", "Service Connected")
        val filter = IntentFilter("com.aicai.app.PERFORM_GLOBAL_ACTION")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(actionReceiver, filter)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // We don't need to process events for now, just performing actions
    }

    override fun onInterrupt() {
        Log.d("GlobalActionService", "Service Interrupted")
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(actionReceiver)
    }
}
