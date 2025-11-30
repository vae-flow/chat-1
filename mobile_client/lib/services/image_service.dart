import 'dart:convert';
import 'dart:io';
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
  final cleanBaseUrl = baseUrl.replaceAll(RegExp(r"/\$"), "");
  
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

/// Analyze an image (local path or URL) and return a list of ReferenceItem
/// The function will try to call a configured Vision API at `baseUrl` if provided,
/// otherwise it will produce a lightweight local analysis (filename, size).
Future<List<ReferenceItem>> analyzeImage({
  required String imagePath,
  required String baseUrl,
  required String apiKey,
  required String model,
}) async {
  // Create a simple image id based on timestamp and filename
  final file = File(imagePath);
  final imageId = 'img_${DateTime.now().millisecondsSinceEpoch}';

  // If no baseUrl or apiKey provided, fallback to basic local analysis
  if (baseUrl.contains('your-oneapi-host') || apiKey.isEmpty) {
    final stat = await file.stat();
    final title = file.uri.pathSegments.last;
    final snippet = 'Local image: $title, size: ${stat.size} bytes';
    return [ReferenceItem(
      title: title,
      url: imagePath,
      snippet: snippet,
      sourceName: 'LocalVision',
      imageId: imageId,
      sourceType: 'vision',
    )];
  }

  try {
    final cleanBase = baseUrl.replaceAll(RegExp(r"/\$") , "");
    // Assume vision endpoint accepts multipart POST at /vision/analyze or /v1/vision/analyze
    Uri uri = Uri.parse('$cleanBase/vision/analyze');

    if (!uri.isAbsolute) {
      uri = Uri.parse('$cleanBase/v1/vision/analyze');
    }

    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = model;
    request.files.add(await http.MultipartFile.fromPath('image', imagePath));

    final streamed = await request.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));

      // Best-effort parsing: accept common keys
      final items = <ReferenceItem>[];
      String title = 'Image Analysis';
      String snippet = '';
      if (data['description'] != null) {
        snippet = data['description'];
      } else if (data['captions'] is List && data['captions'].isNotEmpty) {
        snippet = (data['captions'] as List).join(' ');
      } else if (data['objects'] is List) {
        snippet = (data['objects'] as List).map((o) => o['name']).whereType<String>().join(', ');
      } else {
        snippet = json.encode(data).toString();
      }

      items.add(ReferenceItem(
        title: title,
        url: imagePath,
        snippet: snippet,
        sourceName: 'Vision',
        imageId: imageId,
        sourceType: 'vision',
      ));
      return items;
    } else {
      // Fallback to local analysis if remote fails
      final stat = await file.stat();
      final title = file.uri.pathSegments.last;
      final snippet = 'Vision analyze failed (${resp.statusCode}). Fallback local info. Size: ${stat.size} bytes';
      return [ReferenceItem(
        title: title,
        url: imagePath,
        snippet: snippet,
        sourceName: 'VisionFallback',
        imageId: imageId,
        sourceType: 'vision',
      )];
    }
  } catch (e) {
    final stat = await file.stat();
    final title = file.uri.pathSegments.last;
    final snippet = 'Vision analyze exception: $e. Size: ${stat.size} bytes';
    return [ReferenceItem(
      title: title,
      url: imagePath,
      snippet: snippet,
      sourceName: 'VisionError',
      imageId: imageId,
      sourceType: 'vision',
    )];
  }
}
