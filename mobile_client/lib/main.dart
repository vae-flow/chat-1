import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'screens/chat_page.dart';

void main() {
  tz.initializeTimeZones();
  runApp(const MyApp());
}

// 应用主题色彩 - 优雅紫蓝渐变
class AppColors {
  // 主渐变色
  static const Color primaryStart = Color(0xFF667EEA);  // 优雅紫蓝
  static const Color primaryEnd = Color(0xFF764BA2);    // 深紫
  static const Color accentStart = Color(0xFF6B8DD6);   // 浅蓝紫
  static const Color accentEnd = Color(0xFF8E37D7);     // 亮紫
  
  // 背景渐变
  static const Color bgStart = Color(0xFFF8F9FE);       // 极浅紫白
  static const Color bgEnd = Color(0xFFEEF1F8);         // 浅灰蓝
  
  // 消息气泡
  static const Color userBubbleStart = Color(0xFF667EEA);
  static const Color userBubbleEnd = Color(0xFF764BA2);
  static const Color assistantBubble = Color(0xFFFFFFFF);
  
  // 玻璃效果
  static const Color glassWhite = Color(0xCCFFFFFF);    // 80% 白色
  static const Color glassBorder = Color(0x33FFFFFF);   // 20% 白色边框
  
  // 阴影
  static const Color shadowLight = Color(0x15667EEA);   // 淡紫阴影
  static const Color shadowMedium = Color(0x25667EEA);  // 中紫阴影
  
  // 主渐变
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryStart, primaryEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  // 背景渐变
  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [bgStart, bgEnd],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
  
  // 用户消息渐变
  static const LinearGradient userMessageGradient = LinearGradient(
    colors: [userBubbleStart, userBubbleEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  // 发光效果渐变
  static const LinearGradient glowGradient = LinearGradient(
    colors: [Color(0x40667EEA), Color(0x00667EEA)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 设置状态栏样式
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
    
    return MaterialApp(
      title: 'One-API AI Partner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: AppColors.primaryStart,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primaryStart,
          primary: AppColors.primaryStart,
          secondary: AppColors.primaryEnd,
          surface: Colors.white,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.bgStart,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          elevation: 8,
          highlightElevation: 12,
        ),
        // 优化字体
        textTheme: const TextTheme(
          bodyLarge: TextStyle(letterSpacing: 0.2),
          bodyMedium: TextStyle(letterSpacing: 0.1),
        ),
      ),
      home: const ChatPage(),
    );
  }
}
