import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import '../models/reference_item.dart';

/// Helper function to handle Image Generation API calls (Standard & Chat)
Future<String> fetchImageGenerationUrl({
  required String prompt,
  required String baseUrl,
  required String apiKey,
  required String model,
  required bool useChatApi,
}) async {
  // Normalize URL - only remove trailing slashes, respect user's path
  String cleanBaseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');
  
  if (useChatApi) {
    // Chat API Logic
    final uri = Uri.parse('$cleanBaseUrl/chat/completions');
    final body = json.encode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': prompt}
      ],
      'stream': false,
    });

    final resp = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final content = data['choices'][0]['message']['content'] ?? '';
      
      // Extract URL
      final urlRegExp = RegExp(r'https?://[^\s<>"]+');
      final match = urlRegExp.firstMatch(content);
      if (match != null) {
        String imageUrl = match.group(0)!;
        // Clean punctuation
        final punctuation = [')', ']', '}', '.', ',', ';', '?', '!'];
        while (punctuation.any((p) => imageUrl.endsWith(p))) {
          imageUrl = imageUrl.substring(0, imageUrl.length - 1);
        }
        return imageUrl;
      } else {
        throw Exception('未在返回内容中找到图片链接');
      }
    } else {
      throw Exception('Chat API Error: ${resp.statusCode} ${resp.body}');
    }
  } else {
    // Standard Image API Logic
    final uri = Uri.parse('$cleanBaseUrl/images/generations');
    final body = json.encode({
      'prompt': prompt,
      'model': model,
      'size': '1024x1024',
      'n': 1,
    });

    final resp = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      return data['data'][0]['url'];
    } else {
      throw Exception('Image API Error: ${resp.statusCode} ${resp.body}');
    }
  }
}

/// Helper function to download image to local storage with categorization
enum StorageType { avatar, chatImage, userUpload }

Future<String> downloadAndSaveImage(String url, StorageType type) async {
  final resp = await http.get(Uri.parse(url));
  if (resp.statusCode == 200) {
    return await _saveBytesToStorage(resp.bodyBytes, type);
  } else {
    throw Exception('Download failed: ${resp.statusCode}');
  }
}

/// Helper to save raw bytes to organized storage
Future<String> _saveBytesToStorage(List<int> bytes, StorageType type) async {
  final dir = await getApplicationDocumentsDirectory();
  
  // 1. Determine Sub-directory
  String subDirName;
  String prefix;
  switch (type) {
    case StorageType.avatar:
      subDirName = 'avatars';
      prefix = 'avatar';
      break;
    case StorageType.chatImage:
      subDirName = 'chat_images';
      prefix = 'gen_img';
      break;
    case StorageType.userUpload:
      subDirName = 'user_uploads';
      prefix = 'upload';
      break;
  }

  final subDir = Directory('${dir.path}/$subDirName');
  if (!await subDir.exists()) {
    await subDir.create(recursive: true);
  }

  // 2. Save File
  final fileName = '${prefix}_${DateTime.now().millisecondsSinceEpoch}.png';
  final file = File('${subDir.path}/$fileName');
  await file.writeAsBytes(bytes);
  return file.path;
}

/// Helper to persist picked images (prevent cache cleanup loss)
Future<String> savePickedImage(XFile pickedFile) async {
  final bytes = await pickedFile.readAsBytes();
  return await _saveBytesToStorage(bytes, StorageType.userUpload);
}

/// Analyze an image using OpenAI-compatible Vision API (chat/completions with image_url)
/// Returns a list of ReferenceItem containing the analysis result
/// Supports fallback to another API if primary fails
Future<List<ReferenceItem>> analyzeImage({
  required String imagePath,
  required String baseUrl,
  required String apiKey,
  required String model,
  String? userPrompt, // Optional custom prompt for analysis
  // Fallback config (e.g., Chat API when Vision fails)
  String? fallbackBaseUrl,
  String? fallbackApiKey,
  String? fallbackModel,
}) async {
  final file = File(imagePath);
  final imageId = 'img_${DateTime.now().millisecondsSinceEpoch}';
  final fileName = file.uri.pathSegments.last;

  // Check if primary Vision config is available
  final hasPrimaryConfig = !baseUrl.contains('your-oneapi-host') && apiKey.isNotEmpty;
  final hasFallbackConfig = fallbackBaseUrl != null && 
                            !fallbackBaseUrl.contains('your-oneapi-host') && 
                            fallbackApiKey != null && 
                            fallbackApiKey.isNotEmpty;

  // If no config at all, return basic info
  if (!hasPrimaryConfig && !hasFallbackConfig) {
    final stat = await file.stat();
    return [ReferenceItem(
      title: '图片 (未配置识图API)',
      url: imagePath,
      snippet: '⚠️ 未配置识图 API，无法分析图片内容。文件: $fileName, 大小: ${(stat.size / 1024).toStringAsFixed(1)} KB',
      sourceName: 'LocalOnly',
      imageId: imageId,
      sourceType: 'vision',
    )];
  }

  // Read and encode image as base64 (do this once)
  final bytes = await file.readAsBytes();
  final base64Image = base64Encode(bytes);
  final fileSizeKB = (bytes.length / 1024).round();
  
  // Detect MIME type from extension
  String mimeType = 'image/jpeg';
  final ext = fileName.toLowerCase().split('.').last;
  if (ext == 'png') mimeType = 'image/png';
  else if (ext == 'gif') mimeType = 'image/gif';
  else if (ext == 'webp') mimeType = 'image/webp';

  // Build analysis prompt - use specialized prompts for different scenarios
  String analysisPrompt;
  if (userPrompt != null) {
    analysisPrompt = userPrompt;
  } else {
    // Default: comprehensive multi-scenario analysis with TYPE DECLARATION
    analysisPrompt = '''请分析这张图片。

**第一步：声明图片类型**
请在回答开头用【类型：XXX】格式明确标注图片属于以下哪种类型：
- 📊 表格/电子表格
- 📈 图表（柱状图/折线图/饼图/K线）
- 📄 文档/文字截图
- 💬 聊天记录/对话截图
- 🧾 票据/发票/收据
- 🗺️ 地图/导航截图
- 💻 代码/终端截图
- 🎨 UI界面/设计稿
- 📸 照片/人像/风景
- 🎬 视频截图/电影画面
- 📦 商品/产品图片
- 🔬 医学/科学图像
- 🎮 游戏截图
- 📋 其他

**第二步：根据类型提取信息**

如果是【表格/电子表格】：
- 使用 Markdown 表格格式完整提取所有行列
- 保留数字、日期、金额的精确值

如果是【图表】：
- 提取标题、轴标签、图例
- 列出所有数据点数值

如果是【票据/发票】：
- 提取商家、日期、总金额
- 列出商品明细和单价

如果是【代码/终端】：
- 完整提取代码，保持缩进
- 标注语言和错误信息

如果是【聊天记录】：
- 按顺序提取每条消息
- 标注发送者

如果是【地图/导航】：
- 提取地点、地址、距离

如果是【商品图片】：
- 提取品牌、型号、价格

如果是【照片/其他】：
- 描述主要内容和场景
- 提取可见文字

请用中文回答，确保信息完整准确。''';
  }

  // Try primary Vision API first
  if (hasPrimaryConfig) {
    try {
      final result = await _callVisionApi(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        base64Image: base64Image,
        mimeType: mimeType,
        prompt: analysisPrompt,
        imagePath: imagePath,
        imageId: imageId,
        fileName: fileName,
        fileSizeKB: fileSizeKB,
      );
      if (result != null) return result;
    } catch (e) {
      // Primary failed, will try fallback
      debugPrint('Primary Vision API failed: $e');
    }
  }

  // Try fallback API
  if (hasFallbackConfig) {
    try {
      debugPrint('Trying fallback API for vision...');
      final result = await _callVisionApi(
        baseUrl: fallbackBaseUrl!,
        apiKey: fallbackApiKey!,
        model: fallbackModel ?? model, // Use primary model as fallback if not specified
        base64Image: base64Image,
        mimeType: mimeType,
        prompt: analysisPrompt,
        imagePath: imagePath,
        imageId: imageId,
        fileName: fileName,
        fileSizeKB: fileSizeKB,
        isFallback: true,
      );
      if (result != null) return result;
    } catch (e) {
      debugPrint('Fallback Vision API also failed: $e');
    }
  }

  // Both failed - return error info
  final stat = await file.stat();
  return [ReferenceItem(
    title: '图片分析失败',
    url: imagePath,
    snippet: '⚠️ 识图失败，主备 API 均不可用。\n文件: $fileName, 大小: ${(stat.size / 1024).toStringAsFixed(1)} KB\n请检查识图或对话 API 配置。',
    sourceName: 'VisionError',
    imageId: imageId,
    sourceType: 'vision',
  )];
}

/// Internal helper to call Vision API
Future<List<ReferenceItem>?> _callVisionApi({
  required String baseUrl,
  required String apiKey,
  required String model,
  required String base64Image,
  required String mimeType,
  required String prompt,
  required String imagePath,
  required String imageId,
  String? fileName,
  int? fileSizeKB,
  bool isFallback = false,
}) async {
  // Normalize URL - only remove trailing slashes, respect user's path
  String cleanBase = baseUrl.replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.parse('$cleanBase/chat/completions');

  final body = json.encode({
    'model': model,
    'messages': [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': prompt},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:$mimeType;base64,$base64Image',
              'detail': 'high'
            }
          }
        ]
      }
    ],
    'max_tokens': 4000, // 用户API支持60K tokens
    'stream': false,
  });

  final resp = await http.post(
    uri,
    headers: {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    },
    body: body,
  ).timeout(const Duration(minutes: 2));

  if (resp.statusCode == 200) {
    final data = json.decode(utf8.decode(resp.bodyBytes));
    final content = data['choices']?[0]?['message']?['content'] ?? '';
    
    if (content.isEmpty) {
      throw Exception('API returned empty content');
    }

    final sourceName = isFallback ? 'Chat-Vision ($model)' : 'Vision ($model)';
    
    // Build rich snippet with metadata prefix
    final metaPrefix = (fileName != null || fileSizeKB != null) 
        ? '【文件: ${fileName ?? "unknown"}, ${fileSizeKB ?? "?"}KB, $mimeType】\n'
        : '';
    
    return [ReferenceItem(
      title: '图片分析结果',
      url: imagePath,
      snippet: '$metaPrefix$content',
      sourceName: sourceName,
      imageId: imageId,
      sourceType: 'vision',
    )];
  } else {
    String errorMsg = 'Status ${resp.statusCode}';
    try {
      final errData = json.decode(resp.body);
      errorMsg = errData['error']?['message'] ?? errorMsg;
    } catch (_) {}
    throw Exception('API Error: $errorMsg');
  }
}
