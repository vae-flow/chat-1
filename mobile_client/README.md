# Android APK（Flutter）示例客户端

特点：可视化选择模型，输入 API Base/Key，对话调用 one-api（OpenAI 兼容）。基于 Flutter，可直接 `flutter build apk` 生成安装包。

## 准备
1. 安装 Flutter 3.x（含 Android SDK/模拟器），配置好 `flutter doctor`。
2. 在本仓根目录运行：
   ```bash
   flutter create mobile_client
   ```
   然后用本目录的 `lib/main.dart` 和 `pubspec.yaml` 覆盖生成的同名文件。

## 运行与打包
```bash
cd mobile_client
flutter pub get
flutter run          # 连接真机或模拟器调试
flutter build apk    # 生成 release APK，位于 build/app/outputs/flutter-apk/app-release.apk
```

## 使用
1. 填写：
   - API Base：如 `https://your-oneapi-host/v1`
   - API Key：one-api 后台生成的 `sk-...`
2. 点“拉取模型”，下拉框选择模型（或手填）。
3. 输入对话内容，点击“发送”。支持连续对话（本地保存最近 10 轮）。

## 注意
- 未做证书绕过，请使用 https 或可信 http。
- 未接入流式，单次请求可能稍慢。
- 如需默认写死 base/key/model，可在 `lib/main.dart` 顶部的默认值调整。
