package com.aicai.app.aicai_assistant

import android.content.Intent
import android.provider.Settings
import android.text.TextUtils
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.aicai.app/system_control").setMethodCallHandler { call, result ->
            if (call.method == "performGlobalAction") {
                val actionId = call.argument<Int>("actionId")
                val intent = Intent("com.aicai.app.PERFORM_GLOBAL_ACTION")
                intent.putExtra("actionId", actionId)
                intent.setPackage(context.packageName)
                context.sendBroadcast(intent)
                result.success(true)
            } else if (call.method == "openAccessibilitySettings") {
                val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                startActivity(intent)
                result.success(null)
            } else if (call.method == "isServiceEnabled") {
                var accessibilityEnabled = 0
                val service = context.packageName + "/" + GlobalActionService::class.java.canonicalName
                try {
                    accessibilityEnabled = Settings.Secure.getInt(
                        context.applicationContext.contentResolver,
                        android.provider.Settings.Secure.ACCESSIBILITY_ENABLED
                    )
                } catch (e: Settings.SettingNotFoundException) {
                    // ignored
                }
                val mStringColonSplitter = TextUtils.SimpleStringSplitter(':')
                var found = false
                if (accessibilityEnabled == 1) {
                    val settingValue = Settings.Secure.getString(
                        context.applicationContext.contentResolver,
                        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                    )
                    if (settingValue != null) {
                        mStringColonSplitter.setString(settingValue)
                        while (mStringColonSplitter.hasNext()) {
                            val accessibilityService = mStringColonSplitter.next()
                            if (accessibilityService.equals(service, ignoreCase = true)) {
                                found = true
                                break
                            }
                        }
                    }
                }
                result.success(found)
            } else {
                result.notImplemented()
            }
        }
    }
}
