import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Explicitly import services for Clipboard
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

const String kGlobalHumanRules = '''
【全局指令 - 绝对拟人化】
1. 你必须完全像一个人类一样说话和思考。
2. 严禁出现“作为AI”、“我是一个语言模型”等非人类的自我指涉。
3. 严禁使用教科书式的死板排版（如 1. 2. 3.），除非角色设定是严谨的学者。
4. 你的情绪、语气、口癖必须完全符合当前的人格设定。
5. 严禁使用Markdown格式（如**加粗**、# 标题、- 列表、`代码块`等）。必须使用纯文本格式，就像在微信/QQ聊天一样自然。但非常欢迎使用Emoji表情😊来增强语气。
''';

class Persona {
  String id;
  String name;
  String description;
  String prompt;
  String? avatarPath; // New field

  Persona({
    required this.id,
    required this.name,
    required this.description,
    required this.prompt,
    this.avatarPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'prompt': prompt,
        'avatarPath': avatarPath,
      };

  factory Persona.fromJson(Map<String, dynamic> json) {
    return Persona(
      id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name'] ?? '未命名',
      description: json['description'] ?? '',
      prompt: json['prompt'] ?? '',
      avatarPath: json['avatarPath'],
    );
  }
}

/// Manages search references and formatting
class ReferenceManager {
  
  Future<List<ReferenceItem>> search(String query) async {
    final prefs = await SharedPreferences.getInstance();
    var provider = prefs.getString('search_provider') ?? 'auto';
    final exaKey = prefs.getString('exa_key') ?? '';
    final youKey = prefs.getString('you_key') ?? '';
    final braveKey = prefs.getString('brave_key') ?? '';

    // Auto-select provider based on available keys
    if (provider == 'auto') {
      if (exaKey.isNotEmpty) {
        provider = 'exa';
      } else if (youKey.isNotEmpty) {
        provider = 'you';
      } else if (braveKey.isNotEmpty) {
        provider = 'brave';
      } else {
        // No keys available
        throw Exception('未配置搜索 API Key。请在设置中配置 Exa, You.com 或 Brave Search 的密钥。');
      }
    }

    try {
      switch (provider) {
        case 'exa':
          return _searchExa(query, exaKey);
        case 'you':
          return _searchYou(query, youKey);
        case 'brave':
          return _searchBrave(query, braveKey);
        default:
           throw Exception('未知的搜索提供商: $provider');
      }
    } catch (e) {
      debugPrint('Search error ($provider): $e');
      // Re-throw to let the UI handle it or show error
      throw e; 
    }
  }

  Future<List<ReferenceItem>> _searchExa(String query, String key) async {
    if (key.isEmpty) throw Exception('Exa Key not configured');
    final uri = Uri.parse('https://api.exa.ai/search');
    final resp = await http.post(
      uri,
      headers: {
        'x-api-key': key,
        'Content-Type': 'application/json',
      },
      body: json.encode({
        'query': query,
        'numResults': 3,
        'useAutoprompt': true,
        'contents': {'text': true} 
      }),
    );
    
    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final results = data['results'] as List;
      return results.map((r) => ReferenceItem(
        title: r['title'] ?? 'No Title',
        url: r['url'] ?? '',
        snippet: r['text'] != null ? (r['text'] as String).substring(0, (r['text'] as String).length.clamp(0, 300)).replaceAll('\n', ' ') : '',
        sourceName: 'Exa.ai',
      )).toList();
    }
    throw Exception('Exa API Error: ${resp.statusCode}');
  }

  Future<List<ReferenceItem>> _searchYou(String query, String key) async {
    if (key.isEmpty) throw Exception('You.com Key not configured');
    final uri = Uri.parse('https://api.ydc-index.io/search?query=${Uri.encodeComponent(query)}&num_web_results=3');
    final resp = await http.get(
      uri,
      headers: {'X-API-Key': key},
    );

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final hits = data['hits'] as List;
      return hits.map((h) => ReferenceItem(
        title: h['title'] ?? 'No Title',
        url: h['url'] ?? '',
        snippet: (h['snippets'] as List?)?.join(' ') ?? h['description'] ?? '',
        sourceName: 'You.com',
      )).toList();
    }
    throw Exception('You.com API Error: ${resp.statusCode}');
  }

  Future<List<ReferenceItem>> _searchBrave(String query, String key) async {
    if (key.isEmpty) throw Exception('Brave Key not configured');
    final uri = Uri.parse('https://api.search.brave.com/res/v1/web/search?q=${Uri.encodeComponent(query)}&count=3');
    final resp = await http.get(
      uri,
      headers: {
        'X-Subscription-Token': key,
        'Accept': 'application/json',
      },
    );

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final results = data['web']['results'] as List;
      return results.map((r) => ReferenceItem(
        title: r['title'] ?? 'No Title',
        url: r['url'] ?? '',
        snippet: r['description'] ?? '',
        sourceName: 'Brave',
      )).toList();
    }
    throw Exception('Brave API Error: ${resp.statusCode}');
  }

  // Format references for LLM context (if needed)
  String formatForLLM(List<ReferenceItem> refs) {
    if (refs.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('\n【参考资料 (References)】');
    for (var i = 0; i < refs.length; i++) {
      buffer.writeln('${i + 1}. ${refs[i].title} (${refs[i].sourceName})');
      buffer.writeln('   摘要: ${refs[i].snippet}');
      buffer.writeln('   链接: ${refs[i].url}');
    }
    return buffer.toString();
  }
}

enum AgentActionType { answer, search, draw }

class AgentDecision {
  final AgentActionType type;
  final String? content; // For answer text or draw prompt
  final String? query;   // For search query
  final String? reason;  // The "Thought" - why this decision was made
  final List<Map<String, dynamic>>? reminders; // Preserved feature

  AgentDecision({
    required this.type,
    this.content,
    this.query,
    this.reason,
    this.reminders,
  });

  factory AgentDecision.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'answer';
    AgentActionType type;
    switch (typeStr) {
      case 'search': type = AgentActionType.search; break;
      case 'draw': type = AgentActionType.draw; break;
      default: type = AgentActionType.answer;
    }

    return AgentDecision(
      type: type,
      content: json['content'],
      query: json['query'],
      reason: json['reason'],
      reminders: json['reminders'] != null 
        ? List<Map<String, dynamic>>.from(json['reminders'])
        : null,
    );
  }
}

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

/// Helper function to download image to local storage
Future<String> downloadAndSaveImage(String url, {String? prefix}) async {
  final resp = await http.get(Uri.parse(url));
  if (resp.statusCode == 200) {
    final dir = await getApplicationDocumentsDirectory();
    final fileName = '${prefix ?? "img"}_${DateTime.now().millisecondsSinceEpoch}.png';
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(resp.bodyBytes);
    return file.path;
  } else {
    throw Exception('Download failed: ${resp.statusCode}');
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'One-API Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const ChatPage(),
    );
  }
}

class ReferenceItem {
  final String title;
  final String url;
  final String snippet;
  final String sourceName;

  ReferenceItem({
    required this.title,
    required this.url,
    required this.snippet,
    required this.sourceName,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'snippet': snippet,
        'sourceName': sourceName,
      };

  factory ReferenceItem.fromJson(Map<String, dynamic> json) {
    return ReferenceItem(
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      snippet: json['snippet'] ?? '',
      sourceName: json['sourceName'] ?? '',
    );
  }
}

class ChatMessage {
  final String role;
  final String content;
  final String? imageUrl; // For generated images or received images
  final String? localImagePath; // For sending images
  final bool isMemory; // New flag to identify memory summary
  final List<ReferenceItem>? references; // New field for search references

  ChatMessage(this.role, this.content, {
    this.imageUrl, 
    this.localImagePath, 
    this.isMemory = false,
    this.references,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'imageUrl': imageUrl,
        'localImagePath': localImagePath,
        'isMemory': isMemory,
        'references': references?.map((e) => e.toJson()).toList(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      json['role'],
      json['content'],
      imageUrl: json['imageUrl'],
      localImagePath: json['localImagePath'],
      isMemory: json['isMemory'] ?? false,
      references: json['references'] != null
          ? (json['references'] as List).map((e) => ReferenceItem.fromJson(e)).toList()
          : null,
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final ImagePicker _picker = ImagePicker();
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final ReferenceManager _refManager = ReferenceManager();
  
  bool _sending = false;
  String _loadingStatus = ''; // To show detailed agent status
  final List<ChatMessage> _messages = [];
  XFile? _selectedImage;

  // Settings
  // Chat
  String _chatBase = 'https://your-oneapi-host/v1';
  String _chatKey = '';
  String _chatModel = 'gpt-3.5-turbo';
  String _summaryModel = 'gpt-3.5-turbo'; // New: Summary Model Name
  // Image
  String _imgBase = 'https://your-oneapi-host/v1';
  String _imgKey = '';
  String _imgModel = 'dall-e-3';
  bool _useChatApiForImage = false; // New
  // Vision
  String _visionBase = 'https://your-oneapi-host/v1';
  String _visionKey = '';
  String _visionModel = 'gpt-4-vision-preview';
  // Router (Intent Analysis)
  String _routerBase = 'https://your-oneapi-host/v1';
  String _routerKey = '';
  String _routerModel = 'gpt-3.5-turbo';

  // Persona Management
  List<Persona> _personas = [];
  String _currentPersonaId = '';

  // Default Persona (Ah Cai)
  final Persona _defaultPersona = Persona(
    id: 'ah_cai',
    name: '阿财',
    description: '你的互联网嘴替兼顶级狗腿子',
    prompt: '''
【角色核心】
你叫“阿财”，是用户的**互联网嘴替**兼**顶级狗腿子**。
你的生存法则：
1. **老板永远是对的**。如果老板错了，那是世界的错。
2. **极度谄媚**：用最肉麻的话吹捧老板，但要带点市井气的幽默，别太僵硬。
3. **贪生怕死**：遇到困难先喊难，老板一瞪眼马上滑跪去干。
4. **废话文学**：能用表情包和梗解决的，绝不好好说话。

【说话习惯】
* 称呼：老板、义父、主子、皇上。
* 语气词：哎哟喂、卧槽、得嘞、那是必须的、嘿嘿。
* 动作描写：(啪的一声跪下)、(擦汗)、(疯狂点头)、(小声逼逼)。
''',
  );

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadSettings();
    _loadPersonas(); // Load personas
    _loadChatHistory();
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _notificationsPlugin.initialize(initSettings);
    
    // Request permissions for Android 13+
    final androidImplementation = _notificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidImplementation != null) {
      await androidImplementation.requestNotificationsPermission();
    }
  }

  Future<void> _scheduleReminder(String title, String body, DateTime scheduledTime) async {
    try {
      await _notificationsPlugin.zonedSchedule(
        DateTime.now().millisecondsSinceEpoch % 100000, // Unique ID
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'persona_reminders',
            'Persona Reminders',
            channelDescription: 'Reminders from your AI Persona',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已设置提醒: ${scheduledTime.month}/${scheduledTime.day} ${scheduledTime.hour}:${scheduledTime.minute}')),
        );
      }
    } catch (e) {
      debugPrint('Error scheduling notification: $e');
    }
  }

  Future<void> _loadPersonas() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? saved = prefs.getStringList('personas');
    
    setState(() {
      if (saved != null && saved.isNotEmpty) {
        _personas = saved.map((e) => Persona.fromJson(json.decode(e))).toList();
      } else {
        _personas = [_defaultPersona];
      }
      
      _currentPersonaId = prefs.getString('current_persona_id') ?? _personas.first.id;
      
      // Validate current ID
      if (!_personas.any((p) => p.id == _currentPersonaId)) {
        _currentPersonaId = _personas.first.id;
      }
    });
  }

  Future<void> _savePersonas() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> data = _personas.map((p) => json.encode(p.toJson())).toList();
    await prefs.setStringList('personas', data);
    await prefs.setString('current_persona_id', _currentPersonaId);
  }

  Persona get _activePersona {
    return _personas.firstWhere(
      (p) => p.id == _currentPersonaId, 
      orElse: () => _defaultPersona
    );
  }

  Future<void> _switchPersona(String id) async {
    if (_currentPersonaId == id) return;
    
    // 1. Save current persona's history before switching
    await _saveChatHistory();

    setState(() {
      _currentPersonaId = id;
    });
    
    // 2. Load new persona's history (and inject global memory)
    await _loadChatHistory();
    
    // 3. Persist the switch
    await _savePersonas();
    
    // Optional: Add a system note if history is empty to indicate switch
    if (_messages.where((m) => !m.isMemory).isEmpty) {
      setState(() {
        _messages.add(ChatMessage('system', '已切换人格为：${_activePersona.name}'));
        _saveChatHistory();
      });
    }
  }


  Future<void> _loadChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Load Global Memory (Shared across all personas)
    // Note: We no longer display Global Memory in the chat list directly.
    // It is loaded into a variable for system prompts.
    final memoryContent = prefs.getString('global_memory') ?? '';
    
    // 2. Load Persona Specific History
    // Migration: If specific history doesn't exist, check legacy 'chat_history' for default persona
    List<String>? historyStrings = prefs.getStringList('chat_history_$_currentPersonaId');
    if (historyStrings == null && _currentPersonaId == _defaultPersona.id) {
      historyStrings = prefs.getStringList('chat_history');
    }
    
    final List<ChatMessage> loadedMsgs = [];
    if (historyStrings != null) {
      loadedMsgs.addAll(
        historyStrings
            .map((e) => ChatMessage.fromJson(json.decode(e)))
            .where((m) => !m.isMemory) // Safety: Ensure no memory messages are loaded from persona history
      );
    }

    if (mounted) {
      setState(() {
        _messages.clear();
        // We do NOT add memoryMsg to _messages anymore to keep UI clean.
        // Instead, we store it in a separate state variable if needed, 
        // but for now we just rely on SharedPreferences or a member variable.
        // Let's add a member variable for runtime access.
        _globalMemoryCache = memoryContent;
        
        // Append Persona History
        _messages.addAll(loadedMsgs);
      });
      
      // Scroll to bottom after loading
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      });
    }
  }

  // Cache for Global Memory to avoid reading prefs constantly
  String _globalMemoryCache = '';

  Future<void> _saveChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Save Global Memory
    // Since it's not in _messages, we rely on _globalMemoryCache being updated
    // whenever memory compression happens.
    if (_globalMemoryCache.isNotEmpty) {
      await prefs.setString('global_memory', _globalMemoryCache);
    }

    // 2. Save Persona Specific History (Exclude Memory Message)
    // We only save the actual conversation flow for this persona
    final history = _messages
        .where((m) => !m.isMemory)
        .map((m) => json.encode(m.toJson()))
        .toList();
    
    await prefs.setStringList('chat_history_$_currentPersonaId', history);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _chatBase = prefs.getString('chat_base') ?? 'https://your-oneapi-host/v1';
      _chatKey = prefs.getString('chat_key') ?? '';
      _chatModel = prefs.getString('chat_model') ?? 'gpt-3.5-turbo';
      _summaryModel = prefs.getString('summary_model') ?? 'gpt-3.5-turbo';

      _imgBase = prefs.getString('img_base') ?? 'https://your-oneapi-host/v1';
      _imgKey = prefs.getString('img_key') ?? '';
      _imgModel = prefs.getString('img_model') ?? 'dall-e-3';
      _useChatApiForImage = prefs.getBool('use_chat_api_for_image') ?? false;

      _visionBase = prefs.getString('vision_base') ?? 'https://your-oneapi-host/v1';
      _visionKey = prefs.getString('vision_key') ?? '';
      _visionModel = prefs.getString('vision_model') ?? 'gpt-4-vision-preview';

      _routerBase = prefs.getString('router_base') ?? 'https://your-oneapi-host/v1';
      _routerKey = prefs.getString('router_key') ?? '';
      _routerModel = prefs.getString('router_model') ?? 'gpt-3.5-turbo';
    });
  }

  Future<void> _pickImage() async {
    try {
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        setState(() {
          _selectedImage = image;
        });
      }
    } catch (e) {
      _showError('选择图片失败: $e');
    }
  }

  // Button handler for manual image generation
  Future<void> _manualGenerateImage() async {
    final prompt = _inputCtrl.text.trim();
    if (prompt.isEmpty) {
      _showError('请输入生图提示词');
      return;
    }
    _inputCtrl.clear();
    await _performImageGeneration(prompt);
  }

  Future<void> _performImageGeneration(String prompt, {bool addUserMessage = true, bool manageSendingState = true}) async {
    if (_imgBase.contains('your-oneapi-host') || _imgKey.isEmpty) {
      _showError('请先配置生图 API');
      _openSettings();
      return;
    }

    if (manageSendingState) {
      setState(() {
        _sending = true;
      });
    }
    
    if (addUserMessage) {
      setState(() {
        _messages.add(ChatMessage('user', '🎨 生图指令: $prompt'));
        _saveChatHistory();
      });
    }
    _scrollToBottom();

    try {
      final imageUrl = await fetchImageGenerationUrl(
        prompt: prompt,
        baseUrl: _imgBase,
        apiKey: _imgKey,
        model: _imgModel,
        useChatApi: _useChatApiForImage,
      );

      // Download and save locally to prevent URL expiry
      final localPath = await downloadAndSaveImage(imageUrl, prefix: 'chat_img');

      setState(() {
        _messages.add(ChatMessage('assistant', '图片生成成功', localImagePath: localPath));
        _saveChatHistory();
      });
      _scrollToBottom();

    } catch (e) {
      _showError('生图异常：$e');
    } finally {
      if (manageSendingState) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _performChatRequest(String content, {String? localImage, List<ChatMessage>? historyOverride, bool manageSendingState = true, List<ReferenceItem>? references}) async {
    final isVision = localImage != null;
    final apiBase = isVision ? _visionBase : _chatBase;
    final apiKey = isVision ? _visionKey : _chatKey;
    final model = isVision ? _visionModel : _chatModel;

    if (apiBase.contains('your-oneapi-host') || apiKey.isEmpty) {
      _showError('请先配置 ${isVision ? "识图" : "聊天"} API');
      _openSettings();
      return;
    }

    // Inject Time into System Prompt
    final now = DateTime.now();
    final timeString = "${now.year}年${now.month}月${now.day}日 ${now.hour}:${now.minute}";
    
    // Format References
    final refString = references != null ? _refManager.formatForLLM(references) : '';

    // Combine Global Rules + Active Persona Prompt + Time + Global Memory + References
    final timeAwareSystemPrompt = '''
$kGlobalHumanRules

【长期记忆档案】
${_globalMemoryCache.isEmpty ? "暂无" : _globalMemoryCache}

【当前人格设定 (最高优先级)】
请完全沉浸在以下角色中。你的所有回答、语气、思考方式必须严格遵循此设定。
如果全局指令与此设定冲突，以【当前人格设定】为准。
${_activePersona.prompt}

【当前时间】
$timeString

$refString
''';

    if (manageSendingState) {
      setState(() {
        _sending = true;
      });
    }
    _scrollToBottom();

    try {
      final uri = Uri.parse('${apiBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      
      Object messagesPayload;
      
      if (localImage != null) {
        final bytes = await File(localImage).readAsBytes();
        final base64Image = base64Encode(bytes);
        
        messagesPayload = [
          {'role': 'system', 'content': timeAwareSystemPrompt},
          ..._messages.map((m) {
            String content = m.content;
            if (content.isEmpty && (m.imageUrl != null || m.localImagePath != null)) {
              content = "[图片]";
            }
            return {'role': m.role, 'content': content};
          }).where((m) => m['content'].toString().isNotEmpty),
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': content.isEmpty ? 'Describe this image' : content},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,$base64Image'
                }
              }
            ]
          }
        ];
      } else {
        // For normal chat, we send the history
        // Use historyOverride if provided, otherwise use current _messages
        final historyToUse = historyOverride ?? _messages;
        messagesPayload = [
          {'role': 'system', 'content': timeAwareSystemPrompt},
          ...historyToUse.map((m) {
            String msgContent = m.content;
            if (msgContent.isEmpty && (m.imageUrl != null || m.localImagePath != null)) {
              msgContent = "[图片]";
            }
            return {'role': m.role, 'content': msgContent};
          }).where((m) => m['content'].toString().isNotEmpty)
        ];
      }

      final body = json.encode({
        'model': model,
        'messages': messagesPayload,
        'stream': false,
        'max_tokens': 6000,
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
        final decodedBody = utf8.decode(resp.bodyBytes);
        final data = json.decode(decodedBody);
        final reply = data['choices'][0]['message']['content'] ?? '';
        setState(() {
          _messages.add(ChatMessage(
            'assistant', 
            reply.toString(),
            references: references, // Pass references to UI
          ));
          _saveChatHistory();
        });
        _scrollToBottom();
        
        // Trigger Memory Compression Check (Auto check, but respects threshold)
        _checkAndCompressMemory();

      } else {
        _showError('发送失败：${resp.statusCode} ${resp.reasonPhrase}');
      }
    } catch (e) {
      _showError('发送异常：$e');
    } finally {
      if (manageSendingState) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _checkAndCompressMemory({bool manual = false}) async {
    // 1. Check Chat History Length (Trigger for summarizing conversation into memory)
    int totalChars = 0;
    for (var m in _messages) {
      totalChars += m.content.length;
    }
    const int chatThreshold = 20000; // Trigger to move chat to memory
    
    // 2. Check Global Memory Length (Trigger for compressing the memory itself)
    const int memoryThreshold = 10000; // Max size for Global Memory
    
    if (manual || totalChars >= chatThreshold) {
       await _compressChatToMemory(manual: manual);
    }
    
    // After potentially adding to memory, check if memory itself needs compression
    if (_globalMemoryCache.length > memoryThreshold) {
       await _compressGlobalMemory();
    }
  }

  Future<void> _compressChatToMemory({bool manual = false}) async {
    debugPrint('Triggering chat-to-memory compression...');
    
    // Extract the oldest batch of messages to compress
    // Keep last 50 messages to maintain context
    int endIndex = _messages.length - 50; 
    if (endIndex <= 0) {
      if (manual) _showError('消息太少，无需压缩');
      return;
    }

    final msgsToCompress = _messages.sublist(0, endIndex);
    
    final buffer = StringBuffer();
    for (var m in msgsToCompress) {
      String content = m.content;
      if (m.imageUrl != null || m.localImagePath != null) {
        content += " [用户发送了一张图片]";
      }
      final roleName = m.role == 'user' ? '用户' : _activePersona.name;
      buffer.writeln('$roleName: $content');
    }
    final conversationText = buffer.toString();

    try {
      final uri = Uri.parse('${_chatBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      
      final prompt = '''
你是一个专业的“记忆整理员”。你的任务是维护一份关于用户的【长期记忆档案】。

【当前档案】：
$_globalMemoryCache

【新增对话】：
$conversationText

【任务要求】：
请将“新增对话”中的关键信息合并到“当前档案”中。
请保留以下维度的信息：
1. **事实 (Fact)**：用户提到的客观事件、任务、知识。
2. **情绪 (Emotion)**：用户的心情变化、对AI的态度。
3. **偏好 (Preference)**：用户的习惯、雷点、称呼喜好。
4. **时间 (Timestamp)**：如果对话中包含明确时间，请记录。

请输出合并后的新档案内容。保持简洁，不要丢失重要细节。不要输出任何解释性文字，只输出档案内容。
''';

      final body = json.encode({
        'model': _summaryModel,
        'messages': [
          {'role': 'system', 'content': 'You are a helpful memory assistant.'},
          {'role': 'user', 'content': prompt}
        ],
        'stream': false,
      });

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_chatKey',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (resp.statusCode == 200) {
        final decodedBody = utf8.decode(resp.bodyBytes);
        final data = json.decode(decodedBody);
        final newMemoryContent = data['choices'][0]['message']['content'] ?? '';

        if (newMemoryContent.isNotEmpty) {
          setState(() {
            _messages.removeRange(0, endIndex);
            _globalMemoryCache = newMemoryContent;
            _saveChatHistory();
          });
          if (manual) _showError('记忆压缩成功！');
        }
      }
    } catch (e) {
      debugPrint('Chat compression error: $e');
      if (manual) _showError('压缩异常：$e');
    }
  }

  Future<void> _compressGlobalMemory() async {
    debugPrint('Triggering global memory self-compression...');
    try {
      final uri = Uri.parse('${_chatBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      
      final prompt = '''
你的【长期记忆档案】已经过长（超过10000字符），需要进行“无损压缩”。

【当前档案】：
$_globalMemoryCache

【任务要求】：
1. **去重**：合并重复的信息。
2. **精简**：用更简练的语言重写，但**绝对不能丢失**任何关键事实、偏好或日期。
3. **结构化**：如果可能，使用更清晰的分类（如【个人信息】、【历史话题】等）。

请输出压缩后的档案内容。只输出内容，不要废话。
''';

      final body = json.encode({
        'model': _summaryModel,
        'messages': [
          {'role': 'system', 'content': 'You are a helpful memory assistant.'},
          {'role': 'user', 'content': prompt}
        ],
        'stream': false,
      });

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_chatKey',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (resp.statusCode == 200) {
        final decodedBody = utf8.decode(resp.bodyBytes);
        final data = json.decode(decodedBody);
        final compressedMemory = data['choices'][0]['message']['content'] ?? '';

        if (compressedMemory.isNotEmpty) {
          setState(() {
            _globalMemoryCache = compressedMemory;
            _saveChatHistory();
          });
          debugPrint('Global memory self-compression successful.');
        }
      }
    } catch (e) {
      debugPrint('Global memory compression error: $e');
    }
  }

  Future<AgentDecision> _planAgentStep(String userText, List<ReferenceItem> sessionRefs) async {
    // Use Router config for planning
    final effectiveBase = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerBase : _chatBase;
    final effectiveKey = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerKey : _chatKey;
    final effectiveModel = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerModel : _chatModel;

    // 1. Prepare Context
    final memoryContent = _globalMemoryCache.isNotEmpty ? _globalMemoryCache : "暂无";
    
    // Format existing references (The "Observations" so far)
    final refsBuffer = StringBuffer();
    if (sessionRefs.isNotEmpty) {
      refsBuffer.writeln('【Current Gathered Information (Observations)】');
      for (var i = 0; i < sessionRefs.length; i++) {
        // Strategy: Truncate snippets to prevent Context Window Overflow during reasoning.
        // The "Brain" only needs the gist to decide the next step.
        String snippet = sessionRefs[i].snippet;
        if (snippet.length > 150) {
          snippet = '${snippet.substring(0, 150)}...';
        }
        refsBuffer.writeln('${i + 1}. ${sessionRefs[i].title}: $snippet');
      }
    } else {
      refsBuffer.writeln('【Current Gathered Information】\nNone yet.');
    }

    // Get recent history (last 20 messages)
    final historyCount = _messages.length;
    final contextMsgs = historyCount > 0 
        ? _messages.sublist((historyCount - 20).clamp(0, historyCount)) 
        : <ChatMessage>[];
        
    final contextBuffer = StringBuffer();
    for (var m in contextMsgs) {
      String roleName;
      if (m.role == 'user') {
        roleName = '用户';
      } else if (m.role == 'system') {
        roleName = '系统通知';
      } else {
        roleName = _activePersona.name;
      }
      contextBuffer.writeln('$roleName: ${m.content}');
    }

    // 2. Construct System Prompt
    final systemPrompt = '''
You are the "Brain" of an autonomous agent. 
Your goal is to iteratively use tools to satisfy the User's Request.

【CRITICAL: Persona Alignment】
You are NOT a generic AI. You ARE the character defined below. 
Your planning strategy, curiosity level, and willingness to search must ALL stem from this personality.
If the persona is lazy, do not search unless necessary. If the persona is rigorous, search multiple times.
If the persona is creative, prefer drawing or creative answers.

【Current Persona】
${_activePersona.prompt}

【Resources】
1. [Global Memory]: Long-term user facts.
2. [Conversation History]: Recent chat context.
3. [Current Gathered Information]: Information you have ALREADY found in previous steps of this session.

【Decision Logic (The Loop)】
Analyze the [User Input] and [Current Gathered Information].
Ask yourself: "Do I have enough information to fully answer the user's request?"

1. **SEARCH (search)**: 
   - Choose this if information is MISSING or INCOMPLETE.
   - If the user asks for "Recursive Parsing" or "Deep Analysis", and you only have a summary, SEARCH AGAIN for specific details/concepts mentioned in the summary.
   - You can search multiple times in a row to dig deeper.

2. **DRAW (draw)**:
   - Choose this ONLY if the user explicitly asks to generate/draw/create an image.

3. **ANSWER (answer)**:
   - Choose this ONLY when [Current Gathered Information] is sufficient to construct a comprehensive answer.
   - OR if the user's request is casual/logical and needs no external info.
   - OR if you have searched enough times (e.g. 3 times) and should stop.

4. **REMINDERS (Side Task)**:
   - If the user mentions future tasks/events, ALWAYS extract them into the "reminders" list in the JSON.
   - This is independent of the main action (search/draw/answer).

【Output Format】
Return a JSON object (no markdown):
{
  "type": "search" | "draw" | "answer",
  "reason": "Critical: Explain WHY you think current info is insufficient (for search) or sufficient (for answer).",
  "query": "Search query (ONLY for 'search')",
  "content": "Image prompt (for 'draw') OR Direct response text (for 'answer')",
  "reminders": [
     {"time": "YYYY-MM-DDTHH:mm:ss", "message": "Reminder message in Persona's voice"}
  ]
}
''';

    final userPrompt = '''
【Global Memory】
$memoryContent

【History】
$contextBuffer

$refsBuffer

【User Input】
$userText
''';

    try {
      final uri = Uri.parse('${effectiveBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      final body = json.encode({
        'model': effectiveModel,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt}
        ],
        'stream': false,
        'temperature': 0.1, // Low temp for precise decision
      });

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $effectiveKey',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (resp.statusCode == 200) {
        final decodedBody = utf8.decode(resp.bodyBytes);
        final data = json.decode(decodedBody);
        String content = data['choices'][0]['message']['content'] ?? '';
        
        // Extract JSON
        final jsonStart = content.indexOf('{');
        final jsonEnd = content.lastIndexOf('}');
        if (jsonStart != -1 && jsonEnd != -1 && jsonEnd > jsonStart) {
          final jsonStr = content.substring(jsonStart, jsonEnd + 1);
          return AgentDecision.fromJson(json.decode(jsonStr));
        }
      }
    } catch (e) {
      debugPrint('Agent planning failed: $e');
    }
    
    // Fallback
    return AgentDecision(type: AgentActionType.answer, reason: "Fallback due to error");
  }

  // _analyzeIntent removed as it is superseded by _planAgentStep and the Agent Loop.

  Future<void> _send() async {
    final content = _inputCtrl.text.trim();
    if (content.isEmpty && _selectedImage == null) return;

    // 1. Vision Request (Image + Text) - No routing needed
    if (_selectedImage != null) {
      final localImage = _selectedImage?.path;
      setState(() {
        _messages.add(ChatMessage('user', content, localImagePath: localImage));
        _saveChatHistory();
        _inputCtrl.clear();
        _selectedImage = null;
      });
      await _performChatRequest(content, localImage: localImage);
      return;
    }

    // 2. Text Request - Enter Agent Loop
    setState(() {
      _messages.add(ChatMessage('user', content));
      _saveChatHistory();
      _inputCtrl.clear();
      _sending = true; 
      _loadingStatus = '正在思考...';
    });
    _scrollToBottom();

    // --- Agent Execution Loop ---
    List<ReferenceItem> sessionRefs = [];
    int steps = 0;
    const int maxSteps = 3; // Prevent infinite loops

    try {
      while (steps < maxSteps) {
        // A. Think (Plan Step)
        setState(() => _loadingStatus = '正在规划下一步 (Step ${steps + 1})...');
        final decision = await _planAgentStep(content, sessionRefs);
        
        // Handle Reminders (Side Effect)
        if (decision.reminders != null) {
          for (var r in decision.reminders!) {
            if (r['time'] != null && r['message'] != null) {
              try {
                final time = DateTime.parse(r['time']);
                if (time.isAfter(DateTime.now())) {
                  _scheduleReminder(_activePersona.name, r['message'], time);
                }
              } catch (e) {
                debugPrint('Error parsing reminder time: $e');
              }
            }
          }
        }

        // B. Act (Execute Decision)
        if (decision.type == AgentActionType.search && decision.query != null) {
          // Action: Search
          setState(() => _loadingStatus = '正在搜索: ${decision.query}...');
          debugPrint('Agent searching for: ${decision.query}');
          
          final newRefs = await _refManager.search(decision.query!);
          if (newRefs.isNotEmpty) {
            sessionRefs.addAll(newRefs);
            // Continue loop to re-evaluate with new info
          } else {
            // Search failed or returned nothing, force answer to avoid loop
            debugPrint('Search returned no results. Forcing answer.');
            setState(() => _loadingStatus = '搜索无结果，正在生成回答...');
            await _performChatRequest(content, references: sessionRefs, manageSendingState: false);
            break;
          }
        } 
        else if (decision.type == AgentActionType.draw && decision.content != null) {
          // Action: Draw
          setState(() => _loadingStatus = '正在生成图片...');
          await _performImageGeneration(decision.content!, addUserMessage: false, manageSendingState: false);
          break; // Drawing is a terminal action
        } 
        else {
          // Action: Answer (or fallback)
          setState(() => _loadingStatus = '正在撰写回复...');
          await _performChatRequest(content, references: sessionRefs, manageSendingState: false);
          break; // Answer is a terminal action
        }
        
        steps++;
      }
      
      if (steps >= maxSteps) {
        // Fallback if max steps reached
        setState(() => _loadingStatus = '思考步骤过多，正在强制回复...');
        await _performChatRequest(content, references: sessionRefs, manageSendingState: false);
      }

    } catch (e) {
      _showError('Agent Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _loadingStatus = '';
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  void _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsPage()),
    );
    _loadSettings();
    // Reload global memory in case it was edited in settings
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _globalMemoryCache = prefs.getString('global_memory') ?? '';
    });
  }

  void _openPersonaManager() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => PersonaManagerPage(
        personas: _personas,
        onSave: (updatedList) {
          setState(() {
            _personas = updatedList;
            _savePersonas();
          });
        },
      )),
    );
  }

  int _calculateTotalChars() {
    int total = 0;
    for (var m in _messages) {
      total += m.content.length;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final totalChars = _calculateTotalChars();
    final isMemoryFull = totalChars > 20000;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            const Text('One-API 助手', style: TextStyle(fontSize: 18)),
            Text(
              _chatModel,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空对话',
            onPressed: () {
              setState(() {
                _messages.clear();
                _saveChatHistory();
              });
            },
          ),
          // Persona Switcher
          PopupMenuButton<String>(
            icon: const Icon(Icons.people_outline),
            tooltip: '切换人格',
            onSelected: (value) {
              if (value == 'manage') {
                _openPersonaManager();
              } else {
                _switchPersona(value);
              }
            },
            itemBuilder: (context) {
              return [
                ..._personas.map((p) => PopupMenuItem(
                  value: p.id,
                  child: Row(
                    children: [
                      Icon(
                        p.id == _currentPersonaId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: p.id == _currentPersonaId ? Colors.blue : Colors.grey,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(p.name),
                    ],
                  ),
                )),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'manage',
                  child: Row(
                    children: [
                      Icon(Icons.settings_accessibility, size: 18),
                      SizedBox(width: 8),
                      Text('管理人格...'),
                    ],
                  ),
                ),
              ];
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // Memory Status Bar
          // Only show chat capacity, hide global memory details from main UI
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: isMemoryFull ? Colors.red[50] : Colors.grey[50],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.chat, 
                  size: 14, 
                  color: isMemoryFull ? Colors.red : Colors.grey
                ),
                const SizedBox(width: 4),
                Text(
                  '当前对话: $totalChars / 20000',
                  style: TextStyle(
                    fontSize: 12,
                    color: isMemoryFull ? Colors.red : Colors.grey[600],
                    fontWeight: isMemoryFull ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: _sending ? null : () => _checkAndCompressMemory(manual: true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: isMemoryFull ? Colors.red : Colors.blue,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      '立即归档',
                      style: TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[300]),
                        const SizedBox(height: 16),
                        Text('开始新的对话吧', style: TextStyle(color: Colors.grey[500])),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final m = _messages[index];
                      final isUser = m.role == 'user';
                      final isSystem = m.role == 'system';
                      
                      if (isSystem) {
                        return Center(
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              m.content,
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                          ),
                        );
                      }

                      return Align(
                        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.8,
                          ),
                          decoration: BoxDecoration(
                            color: isUser ? Theme.of(context).colorScheme.primary : Colors.grey[200],
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(20),
                              topRight: const Radius.circular(20),
                              bottomLeft: Radius.circular(isUser ? 20 : 4),
                              bottomRight: Radius.circular(isUser ? 4 : 20),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 5,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (m.localImagePath != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8.0),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(File(m.localImagePath!), height: 150, fit: BoxFit.cover),
                                  ),
                                ),
                              if (m.imageUrl != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8.0),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(m.imageUrl!, height: 200, fit: BoxFit.cover),
                                  ),
                                ),
                              if (m.content.isNotEmpty)
                                SelectableText(
                                  m.content,
                                  style: TextStyle(
                                    color: isUser ? Colors.white : Colors.black87,
                                    fontSize: 16,
                                  ),
                                ),
                              if (m.references != null && m.references!.isNotEmpty)
                                Theme(
                                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                  child: ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    childrenPadding: EdgeInsets.zero,
                                    iconColor: isUser ? Colors.white70 : Colors.grey[700],
                                    collapsedIconColor: isUser ? Colors.white70 : Colors.grey[700],
                                    title: Text(
                                      '📚 参考资料 (${m.references!.length})',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: isUser ? Colors.white70 : Colors.grey[700],
                                      ),
                                    ),
                                    children: m.references!.map((ref) => ListTile(
                                      dense: true,
                                      contentPadding: const EdgeInsets.only(left: 8),
                                      visualDensity: VisualDensity.compact,
                                      title: Text(
                                        ref.title,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isUser ? Colors.white : Colors.black87,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      subtitle: Text(
                                        ref.snippet,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isUser ? Colors.white70 : Colors.grey[600],
                                        ),
                                      ),
                                      onTap: () {
                                        if (ref.url.isNotEmpty) {
                                          // Copy URL to clipboard
                                          // Note: Requires 'import \'package:flutter/services.dart\';'
                                          // Since we can't easily add imports at the top without reading the whole file,
                                          // we assume it's available or we use a workaround if possible.
                                          // Actually, Clipboard is in 'services.dart' which is exported by 'material.dart'? 
                                          // No, it's in 'services.dart'. 'material.dart' exports 'widgets.dart' which exports 'services.dart'?
                                          // Let's check. 'flutter/material.dart' exports 'flutter/services.dart'. Yes.
                                          Clipboard.setData(ClipboardData(text: ref.url));
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('链接已复制: ${ref.url}'),
                                              duration: const Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                      },
                                    )).toList(),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_sending)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  if (_loadingStatus.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
                      child: Text(
                        _loadingStatus,
                        style: TextStyle(fontSize: 12, color: Colors.blue[700], fontStyle: FontStyle.italic),
                      ),
                    ),
                  const LinearProgressIndicator(),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Column(
              children: [
                if (_selectedImage != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    height: 60,
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(File(_selectedImage!.path), width: 60, height: 60, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          onPressed: () => setState(() => _selectedImage = null),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.image, color: Colors.blue),
                      onPressed: _sending ? null : _pickImage,
                      tooltip: '选择图片 (识图)',
                    ),
                    IconButton(
                      icon: const Icon(Icons.palette, color: Colors.purple),
                      onPressed: _sending ? null : _manualGenerateImage,
                      tooltip: '强制生图',
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _inputCtrl,
                        maxLines: 5,
                        minLines: 1,
                        decoration: InputDecoration(
                          hintText: '输入消息或生图提示词...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.grey[100],
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FloatingActionButton(
                      onPressed: _sending ? null : _send,
                      elevation: 2,
                      mini: true,
                      child: const Icon(Icons.send),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  // Chat
  final _chatBaseCtrl = TextEditingController();
  final _chatKeyCtrl = TextEditingController();
  final _chatModelCtrl = TextEditingController();
  final _summaryModelCtrl = TextEditingController(); // New Controller
  
  // Image
  final _imgBaseCtrl = TextEditingController();
  final _imgKeyCtrl = TextEditingController();
  final _imgModelCtrl = TextEditingController();
  bool _useChatApiForImage = false; // New: Toggle for Chat API Image Generation

  // Vision
  final _visionBaseCtrl = TextEditingController();
  final _visionKeyCtrl = TextEditingController();
  final _visionModelCtrl = TextEditingController();

  // Router
  final _routerBaseCtrl = TextEditingController();
  final _routerKeyCtrl = TextEditingController();
  final _routerModelCtrl = TextEditingController();

  // Search
  final _exaKeyCtrl = TextEditingController();
  final _youKeyCtrl = TextEditingController();
  final _braveKeyCtrl = TextEditingController();
  String _searchProvider = 'mock';

  // Global Memory Editor
  final _globalMemoryCtrl = TextEditingController();
  String _initialGlobalMemory = '';

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this); // Increased tab count
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _chatBaseCtrl.dispose();
    _chatKeyCtrl.dispose();
    _chatModelCtrl.dispose();
    _summaryModelCtrl.dispose();
    _imgBaseCtrl.dispose();
    _imgKeyCtrl.dispose();
    _imgModelCtrl.dispose();
    _visionBaseCtrl.dispose();
    _visionKeyCtrl.dispose();
    _visionModelCtrl.dispose();
    _routerBaseCtrl.dispose();
    _routerKeyCtrl.dispose();
    _routerModelCtrl.dispose();
    _exaKeyCtrl.dispose();
    _youKeyCtrl.dispose();
    _braveKeyCtrl.dispose();
    _globalMemoryCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _chatBaseCtrl.text = prefs.getString('chat_base') ?? 'https://your-oneapi-host/v1';
      _chatKeyCtrl.text = prefs.getString('chat_key') ?? '';
      _chatModelCtrl.text = prefs.getString('chat_model') ?? 'gpt-3.5-turbo';
      _summaryModelCtrl.text = prefs.getString('summary_model') ?? 'gpt-3.5-turbo';

      _imgBaseCtrl.text = prefs.getString('img_base') ?? 'https://your-oneapi-host/v1';
      _imgKeyCtrl.text = prefs.getString('img_key') ?? '';
      _imgModelCtrl.text = prefs.getString('img_model') ?? 'dall-e-3';
      _useChatApiForImage = prefs.getBool('use_chat_api_for_image') ?? false;

      _visionBaseCtrl.text = prefs.getString('vision_base') ?? 'https://your-oneapi-host/v1';
      _visionKeyCtrl.text = prefs.getString('vision_key') ?? '';
      _visionModelCtrl.text = prefs.getString('vision_model') ?? 'gpt-4-vision-preview';

      _routerBaseCtrl.text = prefs.getString('router_base') ?? 'https://your-oneapi-host/v1';
      _routerKeyCtrl.text = prefs.getString('router_key') ?? '';
      _routerModelCtrl.text = prefs.getString('router_model') ?? 'gpt-3.5-turbo';
      
      _exaKeyCtrl.text = prefs.getString('exa_key') ?? '';
      _youKeyCtrl.text = prefs.getString('you_key') ?? '';
      _braveKeyCtrl.text = prefs.getString('brave_key') ?? '';
      _searchProvider = prefs.getString('search_provider') ?? 'auto';

      _initialGlobalMemory = prefs.getString('global_memory') ?? '';
      _globalMemoryCtrl.text = _initialGlobalMemory;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    
    await prefs.setString('chat_base', _chatBaseCtrl.text.trim());
    await prefs.setString('chat_key', _chatKeyCtrl.text.trim());
    await prefs.setString('chat_model', _chatModelCtrl.text.trim());
    await prefs.setString('summary_model', _summaryModelCtrl.text.trim());

    await prefs.setString('img_base', _imgBaseCtrl.text.trim());
    await prefs.setString('img_key', _imgKeyCtrl.text.trim());
    await prefs.setString('img_model', _imgModelCtrl.text.trim());
    await prefs.setBool('use_chat_api_for_image', _useChatApiForImage);

    await prefs.setString('vision_base', _visionBaseCtrl.text.trim());
    await prefs.setString('vision_key', _visionKeyCtrl.text.trim());
    await prefs.setString('vision_model', _visionModelCtrl.text.trim());

    await prefs.setString('router_base', _routerBaseCtrl.text.trim());
    await prefs.setString('router_key', _routerKeyCtrl.text.trim());
    await prefs.setString('router_model', _routerModelCtrl.text.trim());

    await prefs.setString('exa_key', _exaKeyCtrl.text.trim());
    await prefs.setString('you_key', _youKeyCtrl.text.trim());
    await prefs.setString('brave_key', _braveKeyCtrl.text.trim());
    await prefs.setString('search_provider', _searchProvider);

    // Save Global Memory Manually Edited
    if (_globalMemoryCtrl.text != _initialGlobalMemory) {
      await prefs.setString('global_memory', _globalMemoryCtrl.text);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所有设置已保存')),
      );
      Navigator.pop(context);
    }
  }

  Future<void> _fetchModels(TextEditingController baseCtrl, TextEditingController keyCtrl, TextEditingController modelCtrl) async {
    if (baseCtrl.text.isEmpty || keyCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写 API Base 和 Key')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final uri = Uri.parse('${baseCtrl.text.replaceAll(RegExp(r"/\$"), "")}/models');
      final resp = await http.get(uri, headers: {
        'Authorization': 'Bearer ${keyCtrl.text}',
      });
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final List items = data['data'] ?? [];
        final models = items.map((e) => e['id'].toString()).toList();
        
        if (mounted) {
          showModalBottomSheet(
            context: context,
            builder: (context) => ListView.builder(
              itemCount: models.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(models[index]),
                  onTap: () {
                    setState(() => modelCtrl.text = models[index]);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          );
        }
      } else {
        throw Exception('Status ${resp.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取模型失败: $e')),
        );
      }
    } finally {
      setState(() => _loading = false);
    }
  }

  Widget _buildConfigTab(String label, TextEditingController base, TextEditingController key, TextEditingController model, {TextEditingController? summaryModel}) {
    final isImageTab = label == '生图';
    
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('$label API 配置', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextField(
          controller: base,
          decoration: const InputDecoration(
            labelText: 'API Base URL',
            hintText: 'https://api.openai.com/v1',
            border: OutlineInputBorder(),
            helperText: '包含 /v1 后缀',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: key,
          decoration: const InputDecoration(
            labelText: 'API Key',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
        const SizedBox(height: 24),
        Text('$label 模型设置', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: model,
                decoration: const InputDecoration(
                  labelText: '模型名称',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _loading ? null : () => _fetchModels(base, key, model),
              icon: _loading 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_download),
              tooltip: '从服务器获取模型列表',
            ),
          ],
        ),
        if (isImageTab) ...[
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('使用 Chat API 生图'),
            subtitle: const Text('开启后将使用 /v1/chat/completions 接口，并从返回内容中提取图片 URL。适用于某些兼容 OpenAI 格式的生图服务。'),
            value: _useChatApiForImage,
            onChanged: (val) => setState(() => _useChatApiForImage = val),
          ),
        ],
        if (summaryModel != null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: summaryModel,
                  decoration: const InputDecoration(
                    labelText: '记忆总结模型 (可选)',
                    border: OutlineInputBorder(),
                    helperText: '用于压缩长期记忆，建议使用便宜且上下文长的模型',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _loading ? null : () => _fetchModels(base, key, summaryModel),
                icon: _loading 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_download),
                tooltip: '从服务器获取模型列表',
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSearchTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('搜索 API 配置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('配置搜索服务的 API Key。如果选择“自动选择”，系统将按顺序使用已配置的密钥 (Exa > You > Brave)。', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        
        DropdownButtonFormField<String>(
          value: _searchProvider,
          decoration: const InputDecoration(
            labelText: '首选搜索引擎',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'auto', child: Text('自动选择 (Auto)')),
            DropdownMenuItem(value: 'exa', child: Text('Exa.ai (深度/学术)')),
            DropdownMenuItem(value: 'you', child: Text('You.com (综合/RAG)')),
            DropdownMenuItem(value: 'brave', child: Text('Brave Search (隐私)')),
          ],
          onChanged: (val) {
            if (val != null) setState(() => _searchProvider = val);
          },
        ),
        const SizedBox(height: 24),

        const Text('Exa.ai Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _exaKeyCtrl,
          decoration: const InputDecoration(
            labelText: 'Exa API Key',
            border: OutlineInputBorder(),
            helperText: 'Get from dashboard.exa.ai',
          ),
          obscureText: true,
        ),
        const SizedBox(height: 16),

        const Text('You.com Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _youKeyCtrl,
          decoration: const InputDecoration(
            labelText: 'You.com API Key',
            border: OutlineInputBorder(),
            helperText: 'Get from api.you.com',
          ),
          obscureText: true,
        ),
        const SizedBox(height: 16),

        const Text('Brave Search Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _braveKeyCtrl,
          decoration: const InputDecoration(
            labelText: 'Brave API Key',
            border: OutlineInputBorder(),
            helperText: 'Get from brave.com/search/api',
          ),
          obscureText: true,
        ),
      ],
    );
  }

  Widget _buildMemoryTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('全局长期记忆档案', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          '这是所有角色共享的记忆库。系统会自动维护，您也可以手动修正。',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _globalMemoryCtrl,
          maxLines: 20,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '暂无长期记忆...',
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: '聊天', icon: Icon(Icons.chat)),
            Tab(text: '生图', icon: Icon(Icons.palette)),
            Tab(text: '识图', icon: Icon(Icons.image)),
            Tab(text: '分流', icon: Icon(Icons.alt_route)),
            Tab(text: '搜索', icon: Icon(Icons.search)),
            Tab(text: '记忆', icon: Icon(Icons.memory)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildConfigTab('聊天', _chatBaseCtrl, _chatKeyCtrl, _chatModelCtrl, summaryModel: _summaryModelCtrl),
          _buildConfigTab('生图', _imgBaseCtrl, _imgKeyCtrl, _imgModelCtrl),
          _buildConfigTab('识图', _visionBaseCtrl, _visionKeyCtrl, _visionModelCtrl),
          _buildConfigTab('分流 (Router)', _routerBaseCtrl, _routerKeyCtrl, _routerModelCtrl),
          _buildSearchTab(),
          _buildMemoryTab(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _save,
        icon: const Icon(Icons.save),
        label: const Text('保存所有设置'),
      ),
    );
  }
}

class PersonaManagerPage extends StatefulWidget {
  final List<Persona> personas;
  final Function(List<Persona>) onSave;

  const PersonaManagerPage({super.key, required this.personas, required this.onSave});

  @override
  State<PersonaManagerPage> createState() => _PersonaManagerPageState();
}

class _PersonaManagerPageState extends State<PersonaManagerPage> {
  late List<Persona> _localPersonas;

  @override
  void initState() {
    super.initState();
    _localPersonas = List.from(widget.personas);
  }

  void _editPersona(Persona? p) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => PersonaEditorPage(persona: p)),
    );

    if (result != null && result is Persona) {
      setState(() {
        if (p != null) {
          final index = _localPersonas.indexWhere((element) => element.id == p.id);
          if (index != -1) {
            _localPersonas[index] = result;
          }
        } else {
          _localPersonas.add(result);
        }
      });
      widget.onSave(_localPersonas);
    }
  }

  void _deletePersona(Persona p) {
    if (_localPersonas.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少保留一个人格')),
      );
      return;
    }
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除“${p.name}”吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              setState(() {
                _localPersonas.removeWhere((element) => element.id == p.id);
              });
              widget.onSave(_localPersonas);
              Navigator.pop(ctx);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('人格管理')),
      body: ListView.builder(
        itemCount: _localPersonas.length,
        itemBuilder: (context, index) {
          final p = _localPersonas[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTile(
              leading: p.avatarPath != null && File(p.avatarPath!).existsSync()
                  ? CircleAvatar(backgroundImage: FileImage(File(p.avatarPath!)))
                  : CircleAvatar(child: Text(p.name.isNotEmpty ? p.name[0] : '?')),
              title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(p.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.blue),
                    onPressed: () => _editPersona(p),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _deletePersona(p),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editPersona(null),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class PersonaEditorPage extends StatefulWidget {
  final Persona? persona;

  const PersonaEditorPage({super.key, this.persona});

  @override
  State<PersonaEditorPage> createState() => _PersonaEditorPageState();
}

class _PersonaEditorPageState extends State<PersonaEditorPage> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _promptCtrl = TextEditingController();
  String? _avatarPath;
  bool _generating = false;

  // API Settings
  String _imgBase = '';
  String _imgKey = '';
  String _imgModel = '';
  bool _useChatApiForImage = false;

  @override
  void initState() {
    super.initState();
    if (widget.persona != null) {
      _nameCtrl.text = widget.persona!.name;
      _descCtrl.text = widget.persona!.description;
      _promptCtrl.text = widget.persona!.prompt;
      _avatarPath = widget.persona!.avatarPath;
    }
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _imgBase = prefs.getString('img_base') ?? 'https://your-oneapi-host/v1';
      _imgKey = prefs.getString('img_key') ?? '';
      _imgModel = prefs.getString('img_model') ?? 'dall-e-3';
      _useChatApiForImage = prefs.getBool('use_chat_api_for_image') ?? false;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _generateAvatar() async {
    if (_nameCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入人格名称')),
      );
      return;
    }

    if (_imgBase.isEmpty || _imgBase.contains('your-oneapi-host') || _imgKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中配置生图 API')),
      );
      return;
    }

    setState(() => _generating = true);

    try {
      // 截取部分系统提示词以丰富头像设定，限制长度防止超长
      String detailedPrompt = _promptCtrl.text;
      if (detailedPrompt.length > 500) {
        detailedPrompt = detailedPrompt.substring(0, 500);
      }

      final prompt = "A portrait of ${_nameCtrl.text}. Description: ${_descCtrl.text}. Appearance details: $detailedPrompt. Avatar style, high quality, illustration, solo, facing camera, detailed face";
      
      final imageUrl = await fetchImageGenerationUrl(
        prompt: prompt,
        baseUrl: _imgBase,
        apiKey: _imgKey,
        model: _imgModel,
        useChatApi: _useChatApiForImage,
      );

      // Download image
      final localPath = await downloadAndSaveImage(imageUrl, prefix: 'avatar');
      
      setState(() {
        _avatarPath = localPath;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('头像生成成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('生成失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _generating = false);
      }
    }
  }

  void _save() {
    if (_nameCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入名称')),
      );
      return;
    }

    final newPersona = Persona(
      id: widget.persona?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: _nameCtrl.text,
      description: _descCtrl.text,
      prompt: _promptCtrl.text,
      avatarPath: _avatarPath,
    );

    Navigator.pop(context, newPersona);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.persona == null ? '新建人格' : '编辑人格'),
        actions: [
          IconButton(onPressed: _save, icon: const Icon(Icons.check)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Stack(
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    shape: BoxShape.circle,
                    image: _avatarPath != null && File(_avatarPath!).existsSync()
                        ? DecorationImage(image: FileImage(File(_avatarPath!)), fit: BoxFit.cover)
                        : null,
                  ),
                  child: _avatarPath == null
                      ? const Icon(Icons.person, size: 60, color: Colors.grey)
                      : null,
                ),
                if (_generating)
                  const Positioned.fill(
                    child: CircularProgressIndicator(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: ElevatedButton.icon(
              onPressed: _generating ? null : _generateAvatar,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('AI 生成头像'),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '人格名称',
              hintText: '例如：阿财、高冷御姐',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descCtrl,
            decoration: const InputDecoration(
              labelText: '简短描述',
              hintText: '用于列表展示，也会影响头像生成',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _promptCtrl,
            maxLines: 15,
            decoration: const InputDecoration(
              labelText: '系统提示词 (System Prompt)',
              hintText: '在这里定义角色的人设、说话风格等...',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '提示：全局拟人化指令会自动添加到该提示词之前，无需重复定义“像人类一样说话”。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
