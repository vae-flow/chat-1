import 'package:flutter/services.dart';

class SystemControl {
  static const MethodChannel _channel = MethodChannel('com.aicai.app/system_control');

  /// Trigger a global system action
  /// [actionId]:
  /// 1: GLOBAL_ACTION_BACK
  /// 2: GLOBAL_ACTION_HOME
  /// 3: GLOBAL_ACTION_RECENTS
  /// 4: GLOBAL_ACTION_NOTIFICATIONS
  /// 5: GLOBAL_ACTION_QUICK_SETTINGS
  /// 6: GLOBAL_ACTION_POWER_DIALOG
  /// 7: GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN
  /// 8: GLOBAL_ACTION_LOCK_SCREEN
  /// 9: GLOBAL_ACTION_TAKE_SCREENSHOT
  static Future<bool> performGlobalAction(int actionId) async {
    try {
      final bool result = await _channel.invokeMethod('performGlobalAction', {'actionId': actionId});
      return result;
    } on PlatformException catch (e) {
      print("Failed to perform global action: '${e.message}'.");
      return false;
    }
  }

  static Future<bool> goHome() => performGlobalAction(2);
  static Future<bool> goBack() => performGlobalAction(1);
  static Future<bool> showRecents() => performGlobalAction(3);
  static Future<bool> showNotifications() => performGlobalAction(4);
  static Future<bool> lockScreen() => performGlobalAction(8);
  static Future<bool> takeScreenshot() => performGlobalAction(9);

  /// Check if the accessibility service is enabled
  static Future<bool> isServiceEnabled() async {
    try {
      final bool isEnabled = await _channel.invokeMethod('isServiceEnabled');
      return isEnabled;
    } on PlatformException catch (e) {
      print("Failed to check service status: '${e.message}'.");
      return false;
    }
  }
  
  /// Open accessibility settings to let user enable the service
  static Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod('openAccessibilitySettings');
    } on PlatformException catch (e) {
      print("Failed to open settings: '${e.message}'.");
    }
  }
}
