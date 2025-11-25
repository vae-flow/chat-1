import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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

class ChatMessage {
  final String role;
  final String content;
  final String? imageUrl; // For generated images or received images
  final String? localImagePath; // For sending images
  final bool isMemory; // New flag to identify memory summary

  ChatMessage(this.role, this.content, {this.imageUrl, this.localImagePath, this.isMemory = false});

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'imageUrl': imageUrl,
        'localImagePath': localImagePath,
        'isMemory': isMemory,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      json['role'],
      json['content'],
      imageUrl: json['imageUrl'],
      localImagePath: json['localImagePath'],
      isMemory: json['isMemory'] ?? false,
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
  
  bool _sending = false;
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
      final uri = Uri.parse('${_imgBase.replaceAll(RegExp(r"/\$"), "")}/images/generations');
      
      // SiliconFlow (and some other providers) have specific requirements for image size
      // Qwen models don't support "1024x1024", they need specific resolutions like "1024x1024" (1:1) or others.
      // But standard DALL-E uses "1024x1024".
      // Also, some models don't support 'n' parameter or 'quality' parameter.
      // To be safe, we try to detect if it's a SiliconFlow model or just send a more compatible payload.
      
      Map<String, dynamic> payload = {
        'prompt': prompt,
        'model': _imgModel,
        'size': '1024x1024',
        'n': 1,
      };

      final body = json.encode(payload);

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_imgKey',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (resp.statusCode == 200) {
        final data = json.decode(utf8.decode(resp.bodyBytes));
        final url = data['data'][0]['url'];
        setState(() {
          _messages.add(ChatMessage('assistant', '图片生成成功', imageUrl: url));
          _saveChatHistory();
        });
        _scrollToBottom();
      } else {
        _showError('生图失败：${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      _showError('生图异常：$e');
    } finally {
      if (manageSendingState) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _performChatRequest(String content, {String? localImage, List<ChatMessage>? historyOverride, bool manageSendingState = true}) async {
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
    
    // Combine Global Rules + Active Persona Prompt + Time + Global Memory
    final timeAwareSystemPrompt = '''
$kGlobalHumanRules

【长期记忆档案】
${_globalMemoryCache.isEmpty ? "暂无" : _globalMemoryCache}

【当前人格设定】
${_activePersona.prompt}

【当前时间】
$timeString
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
            String content = m.content;
            if (content.isEmpty && (m.imageUrl != null || m.localImagePath != null)) {
              content = "[图片]";
            }
            return {'role': m.role, 'content': content};
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
          _messages.add(ChatMessage('assistant', reply.toString()));
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
    // Keep last 10 messages
    int endIndex = _messages.length - 10; 
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
      buffer.writeln('${m.role}: $content');
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

  Future<Map<String, String?>> _analyzeIntent(String text) async {
    // Use Router config, fallback to Chat config if Router not set (optional, but better to be explicit)
    // Here we assume if router key is empty, we might want to skip or use chat key? 
    // Let's enforce Router config for "Intelligent Routing".
    if (_routerBase.contains('your-oneapi-host') || _routerKey.isEmpty) {
      // If Router is not configured, maybe fallback to Chat config?
      // Or just return default chat intent.
      // Let's try to use Chat config as fallback if Router is missing, 
      // but the user specifically asked for a separate device.
      // If both are missing, we can't do anything.
      if (_chatKey.isNotEmpty && !_chatBase.contains('your-oneapi-host')) {
         // Fallback to chat config for routing if router is not set
         // This is a "soft" fallback.
      } else {
         return {'chat_text': text, 'image_prompt': null};
      }
    }

    final effectiveBase = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerBase : _chatBase;
    final effectiveKey = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerKey : _chatKey;
    final effectiveModel = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerModel : _chatModel;

    // Build Context Memory
    // We exclude the last message because that is the current 'text' which was just added in _send()
    final historyCount = _messages.length;
    final contextMsgs = historyCount > 1 
        ? _messages.sublist(0, historyCount - 1) 
        : <ChatMessage>[];
    
    // Extract Global Memory explicitly
    // Use the cache directly
    final memoryContent = _globalMemoryCache.isNotEmpty ? _globalMemoryCache : "无";

    // Take last 6 messages for recent context (excluding the memory message itself if it was in the list)
    final recentMsgs = contextMsgs.where((m) => !m.isMemory).toList();
    final recentContext = recentMsgs.length > 6 
        ? recentMsgs.sublist(recentMsgs.length - 6) 
        : recentMsgs;

    final contextBuffer = StringBuffer();
    for (var m in recentContext) {
      if (m.content.isNotEmpty) {
         contextBuffer.writeln('${m.role}: ${m.content}');
      }
    }
    final contextString = contextBuffer.toString().trim();

    final routerUserContent = '''
【当前人格设定 (Current Persona)】
${_activePersona.prompt}

【长期记忆 (Global Memory)】
$memoryContent

【近期对话上下文 (Recent Context)】
${contextString.isEmpty ? "无 (None)" : contextString}
【上下文结束】

【当前时间】
${DateTime.now().toString()}

【用户当前指令 (Current Input)】
$text
【指令结束】
''';

    try {
      final uri = Uri.parse('${effectiveBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      
      final systemPrompt = '''
You are an intelligent intent classifier and scheduler. 
Analyze the [Current Input] based on the provided [Context], [Current Persona] and [Current Time].

Your task is to determine the user's intent and split it into three components:
1. "image_prompt": If the user wants to generate an image, provide a descriptive English prompt. If no image is requested, set to null.
2. "chat_text": If the user wants to chat or asks a question, provide that text. If the user ONLY wants an image, set to null.
3. "reminders": If the user mentions any future tasks, events, or deadlines, extract them into a list. 
   Each reminder object must have:
   - "time": The absolute ISO 8601 timestamp (YYYY-MM-DDTHH:mm:ss) for when the reminder should trigger. Infer the year/date from [Current Time] if relative (e.g. "next Friday").
   - "message": A short reminder message written STRICTLY in the [Current Persona]'s voice and tone. Use the persona's catchphrases, attitude, and style defined in [Current Persona].

Return a JSON object with exactly these keys. Do NOT use Markdown code blocks (like ```json). Just return the raw JSON string.

Example 1: "Draw a cat" -> {"image_prompt": "A cute cat", "chat_text": null, "reminders": []}
Example 2: "Remind me to buy milk tomorrow at 9am" (Assume now is 2023-10-27) -> 
{
  "image_prompt": null, 
  "chat_text": "Okay, I'll remind you to buy milk tomorrow.", 
  "reminders": [{"time": "2023-10-28T09:00:00", "message": "Master, time to buy milk!"}]
}

Output ONLY the JSON string.
''';

      final body = json.encode({
        'model': effectiveModel,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': routerUserContent}
        ],
        'stream': false,
        'temperature': 0.2, // Low temp for consistent JSON
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
        
        // Try to find JSON in the content (in case model adds extra text)
        final jsonStart = content.indexOf('{');
        final jsonEnd = content.lastIndexOf('}');
        if (jsonStart != -1 && jsonEnd != -1) {
          content = content.substring(jsonStart, jsonEnd + 1);
          final jsonContent = json.decode(content);

          // Handle Reminders
          if (jsonContent.containsKey('reminders') && jsonContent['reminders'] is List) {
            final reminders = jsonContent['reminders'] as List;
            for (var r in reminders) {
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

          return {
            'image_prompt': jsonContent['image_prompt'],
            'chat_text': jsonContent['chat_text'],
          };
        }
      }
    } catch (e) {
      debugPrint('Intent analysis failed: $e');
    }
    // Fallback
    return {'chat_text': text, 'image_prompt': null};
  }

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

    // 2. Text Request - Route via Chat API
    setState(() {
      _messages.add(ChatMessage('user', content));
      _saveChatHistory();
      _inputCtrl.clear();
      _sending = true; // Show loading while analyzing
    });
    _scrollToBottom();

    // Analyze Intent
    final intent = await _analyzeIntent(content);
    final imagePrompt = intent['image_prompt'];
    final chatText = intent['chat_text'];

    // Dispatch
    final tasks = <Future>[];
    
    // Snapshot current history for chat context to avoid race conditions or pollution by image generation
    final chatHistorySnapshot = List<ChatMessage>.from(_messages);

    if (imagePrompt != null) {
      // Don't add user message again, as it's already added above
      // Pass manageSendingState: false to prevent premature UI unlock
      tasks.add(_performImageGeneration(imagePrompt, addUserMessage: false, manageSendingState: false));
    }

    if (chatText != null) {
      // Prepare history for chat: Replace the last user message (which contains the full mixed intent)
      // with the refined chat text (which only contains the chat part).
      // This helps the LLM focus on the chat task without being confused by the image generation request.
      final historyForChat = List<ChatMessage>.from(chatHistorySnapshot);
      if (historyForChat.isNotEmpty && historyForChat.last.role == 'user') {
        historyForChat.removeLast();
        historyForChat.add(ChatMessage('user', chatText));
      }

      // Pass manageSendingState: false to prevent premature UI unlock
      tasks.add(_performChatRequest(chatText, historyOverride: historyForChat, manageSendingState: false));
    } else if (imagePrompt == null) {
      // Fallback if both are null
      setState(() => _sending = false);
    }
    
    if (tasks.isNotEmpty) {
      await Future.wait(tasks);
      // Ensure sending is false after all tasks complete
      if (mounted) {
        setState(() => _sending = false);
      }
    } else {
       // Case: imagePrompt != null BUT chatText == null (User ONLY wanted an image)
       // Handled by tasks.add above.
       // If we are here, it means both are null (handled by else if) or tasks added.
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
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_sending)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: LinearProgressIndicator(),
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

  // Vision
  final _visionBaseCtrl = TextEditingController();
  final _visionKeyCtrl = TextEditingController();
  final _visionModelCtrl = TextEditingController();

  // Router
  final _routerBaseCtrl = TextEditingController();
  final _routerKeyCtrl = TextEditingController();
  final _routerModelCtrl = TextEditingController();

  // Global Memory Editor
  final _globalMemoryCtrl = TextEditingController();
  String _initialGlobalMemory = '';

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this); // Increased tab count
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

      _visionBaseCtrl.text = prefs.getString('vision_base') ?? 'https://your-oneapi-host/v1';
      _visionKeyCtrl.text = prefs.getString('vision_key') ?? '';
      _visionModelCtrl.text = prefs.getString('vision_model') ?? 'gpt-4-vision-preview';

      _routerBaseCtrl.text = prefs.getString('router_base') ?? 'https://your-oneapi-host/v1';
      _routerKeyCtrl.text = prefs.getString('router_key') ?? '';
      _routerModelCtrl.text = prefs.getString('router_model') ?? 'gpt-3.5-turbo';
      
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

    await prefs.setString('vision_base', _visionBaseCtrl.text.trim());
    await prefs.setString('vision_key', _visionKeyCtrl.text.trim());
    await prefs.setString('vision_model', _visionModelCtrl.text.trim());

    await prefs.setString('router_base', _routerBaseCtrl.text.trim());
    await prefs.setString('router_key', _routerKeyCtrl.text.trim());
    await prefs.setString('router_model', _routerModelCtrl.text.trim());

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
      
      // 使用与主界面一致的 URL 处理逻辑
      final uri = Uri.parse('${_imgBase.replaceAll(RegExp(r"/\$"), "")}/images/generations');
      
      final body = json.encode({
        'prompt': prompt,
        'model': _imgModel,
        'size': '1024x1024',
        'n': 1,
      });

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_imgKey',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (resp.statusCode == 200) {
        final data = json.decode(utf8.decode(resp.bodyBytes));
        final url = data['data'][0]['url'];
        
        // Download image
        final imageResp = await http.get(Uri.parse(url));
        if (imageResp.statusCode == 200) {
          final dir = await getApplicationDocumentsDirectory();
          final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.png';
          final file = File('${dir.path}/$fileName');
          await file.writeAsBytes(imageResp.bodyBytes);
          
          setState(() {
            _avatarPath = file.path;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('头像生成成功')),
            );
          }
        }
      } else {
        throw Exception('API Error: ${resp.statusCode} ${resp.body}');
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
