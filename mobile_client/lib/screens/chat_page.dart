import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/persona.dart';
import '../models/chat_message.dart';
import '../models/reference_item.dart';
import '../models/agent_decision.dart';
import '../services/reference_manager.dart';
import '../services/image_service.dart';
import '../utils/constants.dart';
import 'settings_page.dart';
import 'persona_manager_page.dart';

// Top-level function for compute
Future<String> _processHistoryInIsolate(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) return '';
  
  final buffer = StringBuffer();
  final lines = await file.readAsLines();
  for (var line in lines) {
    try {
      final jsonMap = json.decode(line);
      final role = jsonMap['role'] ?? 'unknown';
      final content = jsonMap['content'] ?? '';
      final personaId = jsonMap['persona_id'] ?? 'unknown';
      buffer.writeln('[$personaId] $role: $content');
    } catch (e) {
      // ignore
    }
  }
  return buffer.toString();
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
  bool _enableStream = true; // New: Stream Toggle
  // Image
  String _imgBase = 'https://your-oneapi-host/v1';
  String _imgKey = '';
  String _imgModel = 'dall-e-3';
  bool _useChatApiForImage = false; // New
  // Vision
  String _visionBase = 'https://your-oneapi-host/v1';
  String _visionKey = '';
  String _visionModel = 'gpt-4-vision-preview';
  // Router
  String _routerBase = 'https://your-oneapi-host/v1';
  String _routerKey = '';
  String _routerModel = 'gpt-3.5-turbo';
  // Profiler
  String _profileBase = 'https://your-oneapi-host/v1';
  String _profileKey = '';
  String _profileModel = 'gpt-3.5-turbo';

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
      for (var e in historyStrings) {
        try {
          final m = ChatMessage.fromJson(json.decode(e));
          if (!m.isMemory) {
            loadedMsgs.add(m);
          }
        } catch (err) {
          debugPrint('Error loading message: $err');
        }
      }
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
    try {
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
    } catch (e) {
      debugPrint('Failed to save chat history: $e');
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _chatBase = prefs.getString('chat_base') ?? 'https://your-oneapi-host/v1';
      _chatKey = prefs.getString('chat_key') ?? '';
      _chatModel = prefs.getString('chat_model') ?? 'gpt-3.5-turbo';
      _summaryModel = prefs.getString('summary_model') ?? 'gpt-3.5-turbo';
      _enableStream = prefs.getBool('enable_stream') ?? true;

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

      _profileBase = prefs.getString('profile_base') ?? 'https://your-oneapi-host/v1';
      _profileKey = prefs.getString('profile_key') ?? '';
      _profileModel = prefs.getString('profile_model') ?? 'gpt-3.5-turbo';
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
      final localPath = await downloadAndSaveImage(imageUrl, StorageType.chatImage);

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

  Future<String> _smartCompress(String text) async {
    // If text is small enough, just return it (though this function is usually called when it's big)
    if (text.length < 1000) return text;

    // Chunking (10k chars)
    const int chunkSize = 10000;
    final chunks = <String>[];
    for (int i = 0; i < text.length; i += chunkSize) {
      int end = (i + chunkSize < text.length) ? i + chunkSize : text.length;
      chunks.add(text.substring(i, end));
    }

    final buffer = StringBuffer();
    for (var chunk in chunks) {
      // Summarize each chunk
      final summary = await _generateSummary(chunk, 0.5); // 50% compression target
      buffer.writeln(summary);
    }
    
    return buffer.toString();
  }

  Future<List<ChatMessage>> _ensureContextFits(List<ChatMessage> history, int limit) async {
    int total = history.fold(0, (p, c) => p + c.content.length);
    if (total <= limit) return history;

    // Keep last 2 messages always (User + Assistant usually) to maintain immediate context
    int keepCount = 2;
    if (history.length <= keepCount) {
       // Can't compress further without losing immediate context. 
       return history; 
    }

    List<ChatMessage> recent = history.sublist(history.length - keepCount);
    List<ChatMessage> older = history.sublist(0, history.length - keepCount);
    
    // Compress older
    String olderText = older.map((m) {
      // Handle previous summaries or system messages distinctly
      if (m.role == 'system') {
         return "【系统/历史信息】: ${m.content}";
      }
      return "${m.role}: ${m.content}";
    }).join("\n");
    
    // Recursive Compression
    // 1. Compress the older text
    String compressedOlder = await _smartCompress(olderText); 
    
    // 2. Create a summary message with explicit temporal marker
    ChatMessage summaryMsg = ChatMessage(
      'system', 
      '【历史对话摘要】\n注意：以下内容是早期对话的压缩记录，发生在后续消息之前。\n$compressedOlder', 
      isMemory: true
    );
    
    List<ChatMessage> newList = [summaryMsg, ...recent];
    
    // 3. Check again (Recursion)
    // If the new list is still too big, we recurse.
    // Note: We need to be careful about infinite loops. 
    // If compression didn't reduce size (unlikely with LLM), we might loop.
    // But _smartCompress uses 0.5 ratio, so it should reduce.
    int newTotal = newList.fold(0, (p, c) => p + c.content.length);
    if (newTotal < total) { // Only recurse if we made progress
       return _ensureContextFits(newList, limit);
    } else {
       return newList; // Stop if we can't reduce further
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

【用户画像 (User Profile)】
(这是你对屏幕对面这个人的深度了解。请利用这些信息来调整你的语气、用词和回答策略，使其最贴合用户的个性与需求。)
${_globalMemoryCache.isEmpty ? "暂无画像，请通过对话逐步了解用户。" : _globalMemoryCache}

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
        var historyToUse = historyOverride ?? _messages;

        // Enforce Context Limit (~30k chars final target) using Recursive Compression
        // If history is too long, we compress it recursively until it fits.
        // User's API supports 30K context, so we use higher limits
        if (historyToUse.fold(0, (sum, m) => sum + m.content.length) > 25000) {
           if (manageSendingState) {
             setState(() => _loadingStatus = '上下文过长，正在递归压缩...');
           }
           historyToUse = await _ensureContextFits(historyToUse, 30000);
        }

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
        'stream': _enableStream,
        'max_tokens': 30000,
      });

      if (_enableStream) {
        // Streaming Logic
        final request = http.Request('POST', uri);
        request.headers.addAll({
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        });
        request.body = body;

        // Add placeholder message
        setState(() {
          _messages.add(ChatMessage('assistant', '', references: references));
        });
        _scrollToBottom();

        final streamedResponse = await http.Client().send(request).timeout(const Duration(minutes: 5));

        if (streamedResponse.statusCode == 200) {
          String fullContent = '';
          await for (final line in streamedResponse.stream.transform(utf8.decoder).transform(const LineSplitter())) {
            if (line.startsWith('data: ')) {
              final data = line.substring(6).trim();
              if (data == '[DONE]') break;
              try {
                final jsonVal = json.decode(data);
                final delta = jsonVal['choices']?[0]?['delta']?['content'];
                if (delta != null) {
                  fullContent += delta;
                  setState(() {
                    // Update last message content
                    final lastMsg = _messages.last;
                    _messages[_messages.length - 1] = ChatMessage(
                      lastMsg.role,
                      fullContent,
                      references: lastMsg.references,
                      imageUrl: lastMsg.imageUrl,
                      localImagePath: lastMsg.localImagePath,
                    );
                  });
                  // Optional: Throttle scrolling if needed
                }
              } catch (e) {
                // ignore parse error
              }
            }
          }
          _saveChatHistory();
          // _checkAndCompressMemory(); // Removed auto-compress as per user request
        } else {
           // Stream request failed, remove placeholder
           setState(() {
             _messages.removeLast();
           });
           _showError('Stream Error: ${streamedResponse.statusCode}');
        }

      } else {
        // Non-Streaming Logic (Legacy)
        final resp = await http.post(
          uri,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: body,
        ).timeout(const Duration(minutes: 5));

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
          
          // _checkAndCompressMemory(); // Removed auto-compress as per user request

        } else {
          _showError('发送失败：${resp.statusCode} ${resp.reasonPhrase}');
        }
      }
    } catch (e) {
      _showError('发送异常：$e');
    } finally {
      if (manageSendingState) {
        setState(() => _sending = false);
      }
    }
  }

  // New: Archive all active messages that haven't been archived yet
  Future<void> _archiveAllActiveMessages() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/chat_archive.jsonl');
      final sink = file.openWrite(mode: FileMode.append);
      
      bool hasUpdates = false;
      for (int i = 0; i < _messages.length; i++) {
        final m = _messages[i];
        if (!m.isArchived) {
          final jsonMap = m.toJson();
          // Add Indexing Metadata
          jsonMap['archived_at'] = DateTime.now().toIso8601String();
          jsonMap['persona_id'] = _currentPersonaId;
          jsonMap['sequence_id'] = DateTime.now().microsecondsSinceEpoch; // Simple sequence
          
          sink.writeln(json.encode(jsonMap));
          
          // Update state to mark as archived
          _messages[i] = m.copyWith(isArchived: true);
          hasUpdates = true;
        }
      }
      
      await sink.flush();
      await sink.close();
      
      if (hasUpdates) {
        _saveChatHistory();
      }
    } catch (e) {
      debugPrint('Archive error: $e');
    }
  }

  // New: Adaptive Compression Logic with Multi-Pass Support
  Future<void> _performAdaptiveCompression() async {
    if (_messages.isEmpty) return;
    
    setState(() {
      _loadingStatus = '正在归档并压缩记忆...';
      _sending = true;
    });

    // 1. Archive everything first (Safety & Profiling Source)
    await _archiveAllActiveMessages();

    // 2. Calculate current total to decide compression strategy
    int currentTotal = _messages.fold(0, (sum, m) => sum + m.content.length);
    debugPrint('Compression started. Current total: $currentTotal chars');

    // 3. Adaptive Summarization with Multi-Pass Support
    // Strategy:
    // - Recent messages (last 5): Keep 60-80% detail
    // - Older messages: Aggressively compress to 15-30%
    // - Already compressed messages: Can be re-compressed if still too long
    
    try {
      int compressedCount = 0;
      int mergedCount = 0;

      // Phase 1: Individual message compression
      for (int i = 0; i < _messages.length; i++) {
        final indexFromEnd = _messages.length - 1 - i;
        
        // Determine target ratio based on recency
        double targetRatio;
        if (indexFromEnd <= 2) {
          targetRatio = 0.8; // Very recent: keep 80%
        } else if (indexFromEnd <= 5) {
          targetRatio = 0.5; // Recent: keep 50%
        } else if (indexFromEnd <= 10) {
          targetRatio = 0.3; // Older: keep 30%
        } else {
          targetRatio = 0.15; // Very old: keep 15%
        }
        
        // Skip system messages or images
        if (_messages[i].role == 'system' || _messages[i].imageUrl != null || _messages[i].localImagePath != null) {
           continue;
        }

        final currentContent = _messages[i].content;
        final currentRatio = _messages[i].compressionRatio;
        final originalLen = _messages[i].originalLength ?? currentContent.length;
        
        // If text is short, don't compress
        if (currentContent.length < 80) continue;

        // Allow re-compression if:
        // 1. Never compressed, OR
        // 2. Current ratio is higher than target (can compress more), OR
        // 3. Content is still long (> 500 chars) and current ratio > target * 0.7
        bool shouldCompress = currentRatio == null ||
            currentRatio > targetRatio ||
            (currentContent.length > 500 && currentRatio > targetRatio * 0.7);
        
        if (!shouldCompress) continue;

        setState(() => _loadingStatus = '压缩消息 ${i + 1}/${_messages.length}...');

        final summary = await _generateSummary(currentContent, targetRatio);
        
        // Only accept if actually shorter (compression worked)
        if (summary.length < currentContent.length * 0.95) {
          final actualRatio = summary.length / originalLen;
          setState(() {
            _messages[i] = _messages[i].copyWith(
              content: summary,
              isCompressed: true,
              originalLength: originalLen,
              compressionRatio: actualRatio,
            );
          });
          compressedCount++;
        } else {
          debugPrint('Compression did not reduce size for message $i, skipping');
        }
      }

      // Phase 2: Merge very old short messages into summary blocks
      // This handles the case where many small messages accumulate
      currentTotal = _messages.fold(0, (sum, m) => sum + m.content.length);
      if (currentTotal > 20000 && _messages.length > 15) {
        setState(() => _loadingStatus = '合并历史消息块...');
        
        // Find consecutive older messages (not in last 10) that can be merged
        final mergeCandidates = <int>[];
        for (int i = 0; i < _messages.length - 10; i++) {
          if (_messages[i].role != 'system' && 
              _messages[i].imageUrl == null && 
              _messages[i].localImagePath == null) {
            mergeCandidates.add(i);
          }
        }
        
        // Merge in chunks of 5
        if (mergeCandidates.length >= 5) {
          for (int start = 0; start < mergeCandidates.length - 4; start += 5) {
            final chunk = mergeCandidates.sublist(start, (start + 5).clamp(0, mergeCandidates.length));
            if (chunk.length < 3) continue;
            
            // Combine content
            final combined = chunk.map((idx) => '${_messages[idx].role}: ${_messages[idx].content}').join('\n');
            if (combined.length < 200) continue; // Not worth merging
            
            // Summarize the combined block
            final blockSummary = await _generateSummary(combined, 0.2);
            
            if (blockSummary.length < combined.length * 0.5) {
              // Replace first message in chunk with summary, mark others for removal
              final firstIdx = chunk.first;
              setState(() {
                _messages[firstIdx] = ChatMessage(
                  'system',
                  '【历史摘要】\n$blockSummary',
                  isMemory: true,
                  isCompressed: true,
                  compressionRatio: 0.2,
                );
                // Mark other messages in chunk as empty (will be filtered later)
                for (int j = 1; j < chunk.length; j++) {
                  _messages[chunk[j]] = _messages[chunk[j]].copyWith(content: '');
                }
              });
              mergedCount++;
            }
          }
          
          // Remove empty messages
          setState(() {
            _messages.removeWhere((m) => m.content.isEmpty && m.imageUrl == null && m.localImagePath == null);
          });
        }
      }
      
      _saveChatHistory();
      
      final newTotal = _messages.fold(0, (sum, m) => sum + m.content.length);
      _showError('压缩完成! $compressedCount条消息压缩, $mergedCount块合并. 总字符: $currentTotal → $newTotal');

    } catch (e) {
      _showError('压缩失败: $e');
    } finally {
      setState(() {
        _loadingStatus = '';
        _sending = false;
      });
    }
  }

  Future<String> _generateSummary(String text, double ratio) async {
    // Use the summary model
    final effectiveBase = (_chatBase.contains('your-oneapi-host')) ? 'https://api.openai.com/v1' : _chatBase;
    final effectiveKey = _chatKey;
    
    final prompt = '''
Please summarize the following text to retain approximately ${(ratio * 100).toInt()}% of the original information density.
Focus on key facts and decisions.
Original Text:
$text
''';

    try {
      final uri = Uri.parse('${effectiveBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      final body = json.encode({
        'model': _summaryModel,
        'messages': [
          {'role': 'system', 'content': 'You are a concise summarizer.'},
          {'role': 'user', 'content': prompt}
        ],
        'stream': false,
      });

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $effectiveKey',
          'Content-Type': 'application/json',
        },
        body: body,
      ).timeout(const Duration(minutes: 5));

      if (resp.statusCode == 200) {
        final decodedBody = utf8.decode(resp.bodyBytes);
        final data = json.decode(decodedBody);
        return data['choices'][0]['message']['content'] ?? text;
      }
    } catch (e) {
      debugPrint('Summary failed: $e');
    }
    return text; // Fallback
  }

  Future<void> _performDeepProfiling() async {
    if (_profileBase.contains('your-oneapi-host') || _profileKey.isEmpty) {
      _showError('请先在设置中配置 Profiler API');
      _openSettings();
      return;
    }

    // Use a notifier to update a modal progress dialog so the UI doesn't appear to "hang".
    final ValueNotifier<String> progress = ValueNotifier<String>('准备读取历史记录...');

    if (!mounted) return;

    // Show non-dismissible progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                ValueListenableBuilder<String>(
                  valueListenable: progress,
                  builder: (context, value, _) => Text(value, textAlign: TextAlign.center),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // CRITICAL: Wait for dialog to render before heavy operations
    await Future.delayed(const Duration(milliseconds: 50));

    setState(() {
      _loadingStatus = '正在读取全量历史记录...';
      _sending = true;
    });

    // Yield to UI thread to ensure dialog is visible
    await Future.delayed(const Duration(milliseconds: 50));

    try {
      debugPrint('Deep profiling started');

      // 1. Gather ALL History (Archive + Active)
      final dir = await getApplicationDocumentsDirectory();
      final archivePath = '${dir.path}/chat_archive.jsonl';
      final allHistoryBuffer = StringBuffer();

      // Read Archive in Isolate (non-blocking)
      progress.value = '读取归档记录...';
      debugPrint('Reading archive from $archivePath');
      final archiveContent = await compute(_processHistoryInIsolate, archivePath);
      allHistoryBuffer.write(archiveContent);
      debugPrint('Archive read complete, length: ${archiveContent.length}');

      // Add unarchived active messages
      progress.value = '合并当前会话消息...';
      for (var m in _messages) {
        if (!m.isArchived) {
          allHistoryBuffer.writeln('[${_activePersona.id}] ${m.role}: ${m.content}');
        }
      }

      final fullText = allHistoryBuffer.toString();
      if (fullText.isEmpty) {
        progress.value = '无足够历史记录';
        _showError('没有足够的历史记录进行刻画');
        setState(() {
          _loadingStatus = '';
          _sending = false;
        });
        Navigator.of(context, rootNavigator: true).pop();
        progress.dispose();
        return;
      }

      // 2. Chunking (Safe limit: 10000 chars to avoid token limits)
      const int chunkSize = 10000;
      final chunks = <String>[];
      for (int i = 0; i < fullText.length; i += chunkSize) {
        int end = (i + chunkSize < fullText.length) ? i + chunkSize : fullText.length;
        chunks.add(fullText.substring(i, end));
      }

      String currentProfile = _globalMemoryCache;

      // 3. Iterative Profiling with retries and non-blocking UI updates
      for (int i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        final statusText = '正在深度刻画... (${i + 1}/${chunks.length})';
        progress.value = statusText;
        setState(() => _loadingStatus = statusText);

        // Build prompt
        final prompt = '''
你是一位拥有超强洞察力的“首席用户侧写师”。
这是用户历史对话的第 ${i + 1}/${chunks.length} 部分。请基于【当前画像】和【本段对话】，更新用户画像。

【当前画像】：
$currentProfile

【本段对话片段】：
$chunk

【核心指令】：
1. **融合更新**：将【当前画像】作为基础，融合【本段对话】中的新信息。
2. **严格保留**：【当前画像】中已有的关键信息（如性格、习惯、背景）必须保留，严禁直接覆盖或丢失。
3. **动态聚类**：观察信息点，自动归纳出最能概括这些信息的类别。
4. **深度推断**：透过现象看本质。

请输出更新后的画像。只输出内容。
''';

        final uri = Uri.parse('${_profileBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
        final body = json.encode({
          'model': _profileModel,
          'messages': [
            {'role': 'system', 'content': 'You are a helpful memory assistant.'},
            {'role': 'user', 'content': prompt}
          ],
          'stream': false,
        });

        // Retry logic for each chunk
        String? newProfile;
        const int maxRetries = 2;
        int attempt = 0;
        while (attempt <= maxRetries) {
          try {
            final resp = await http.post(
              uri,
              headers: {
                'Authorization': 'Bearer $_profileKey',
                'Content-Type': 'application/json',
              },
              body: body,
            ).timeout(const Duration(minutes: 2));

            if (resp.statusCode == 200) {
              final decodedBody = utf8.decode(resp.bodyBytes);
              final data = json.decode(decodedBody);
              final candidate = data['choices']?[0]?['message']?['content'] ?? '';
              if (candidate != null && candidate.toString().trim().isNotEmpty) {
                newProfile = candidate.toString();
              }
              break;
            } else {
              debugPrint('Profiling chunk $i attempt $attempt failed: ${resp.statusCode}');
            }
          } catch (e) {
            debugPrint('Profiling chunk $i attempt $attempt error: $e');
          }

          attempt++;
          // Backoff before retrying
          await Future.delayed(Duration(seconds: 1 + attempt * 2));
        }

        if (newProfile != null && newProfile.isNotEmpty) {
          currentProfile = newProfile;
        } else {
          debugPrint('Profiling chunk $i failed after $maxRetries retries. Continuing.');
        }

        // Yield to UI to keep it responsive
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // 4. Final Save
      setState(() {
        _globalMemoryCache = currentProfile;
        _saveChatHistory();
        _loadingStatus = '';
        _sending = false;
      });
      progress.value = '深度刻画完成';
      _showError('深度刻画完成！');
    } catch (e) {
      debugPrint('Deep profiling exception: $e');
      _showError('刻画失败: $e');
      setState(() {
        _loadingStatus = '';
        _sending = false;
      });
    } finally {
      if (mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
      }
      try {
        progress.dispose();
      } catch (_) {}
    }
  }

  Future<AgentDecision> _planAgentStep(String userText, List<ReferenceItem> sessionRefs, List<AgentDecision> previousDecisions) async {
    // Use Router config for planning
    final effectiveBase = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerBase : _chatBase;
    final effectiveKey = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerKey : _chatKey;
    final effectiveModel = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerModel : _chatModel;

    // 1. Prepare Context Data
    final now = DateTime.now();
    final timeString = "${now.year}年${now.month}月${now.day}日 ${now.hour}:${now.minute} (星期${['','一','二','三','四','五','六','日'][now.weekday]})";
    final memoryContent = _globalMemoryCache.isNotEmpty ? _globalMemoryCache : "暂无";
    
    // Format References (Observations)
    final refsBuffer = StringBuffer();
    if (sessionRefs.isNotEmpty) {
      for (var i = 0; i < sessionRefs.length; i++) {
        String snippet = sessionRefs[i].snippet;
        if (snippet.length > 800) {
          snippet = '${snippet.substring(0, 800)}...';
        }
        refsBuffer.writeln('${i + 1}. ${sessionRefs[i].title}: $snippet');
      }
    } else {
      refsBuffer.writeln('None yet.');
    }

    // Format Previous Actions
    final prevActionsBuffer = StringBuffer();
    if (previousDecisions.isNotEmpty) {
      for (var i = 0; i < previousDecisions.length; i++) {
        final d = previousDecisions[i];
        final contentInfo = d.query ?? d.content ?? 'N/A';
        prevActionsBuffer.writeln('${i + 1}. Action: ${d.type.name.toUpperCase()} | Target: "$contentInfo" | Reason: ${d.reason}');
      }
    } else {
      prevActionsBuffer.writeln('None yet.');
    }

    // Format Chat History
    final historyCount = _messages.length;
    var contextMsgs = historyCount > 0 
        ? _messages.sublist((historyCount - 20).clamp(0, historyCount)) 
        : <ChatMessage>[];
    
    // Enforce Soft Limit (~10k chars) for Agent Context
    int agentContextChars = 0;
    final limitedAgentMsgs = <ChatMessage>[];
    for (final m in contextMsgs.reversed) {
      if (agentContextChars + m.content.length > 10000) break;
      agentContextChars += m.content.length;
      limitedAgentMsgs.add(m);
    }
    contextMsgs = limitedAgentMsgs.reversed.toList();
        
    final contextBuffer = StringBuffer();
    for (var m in contextMsgs) {
      String roleName;
      if (m.role == 'user') {
        roleName = 'User';
      } else if (m.role == 'system') {
        roleName = 'System';
      } else {
        roleName = 'Assistant (${_activePersona.name})';
      }
      contextBuffer.writeln('$roleName: ${m.content}');
    }

    // 2. Construct System Prompt with XML Tags for strict separation
    final systemPrompt = '''
You are the "Brain" of an advanced autonomous agent. 
Your goal is to satisfy the User's Request through iterative reasoning and tool usage.

### INPUT STRUCTURE
The user message is strictly structured. You must distinguish between:
- <current_time>: The precise current time. Use this for relative time queries (e.g. "today", "last week").
- <user_profile>: Deep psychological and factual profile of the user. Use this to infer intent and tailor your strategy.
- <chat_history>: Recent conversation context.
- <current_observations>: Information gathered from search tools in THIS session.
- <action_history>: Actions you have already performed in THIS session.
- <user_input>: The actual request from the user.

### PERSONA DEFINITION (CRITICAL)
You are NOT a generic AI. You must act according to:
<persona>
${_activePersona.prompt}
</persona>

### STRATEGIC THINKING (Chain of Thought)
Before deciding, perform a "Strategic Analysis" in the `reason` field:
1. **Time Awareness**: Check <current_time>. If the user asks for "latest news", "weather", or "stock price", you MUST use the current date in your search query.
2. **Intent Classification**: Is the user asking for a Fact, an Opinion, a Creative Work, or just Chatting?
3. **Gap Analysis**: Compare <user_input> with <current_observations>. What specific information is missing?
4. **Iteration Check**: Look at <action_history>. 
   - If previous searches failed, CHANGE your keywords or strategy.
   - If you have searched 2+ times and have partial info, consider if it's "good enough" to answer.

### DECISION LOGIC
1. **SEARCH (search)**: 
   - USE WHEN: Information is missing, outdated, or needs verification.
   - STRATEGY: Use specific, targeted queries. If "Python tutorial" failed, try "Python for beginners 2024".
   - SINGLE TARGET: Focus on ONE specific information target per search step. If you need A and B, search A first, then search B in the next step. Do NOT combine unrelated topics.
   - RECURSIVE: If the user asks for "Deep Dive", and you found a summary, search again for the specific terms in that summary.

2. **DRAW (draw)**:
   - USE WHEN: User explicitly asks for an image/drawing/painting.

3. **ANSWER (answer)**:
   - USE WHEN: <current_observations> are sufficient.
   - OR: The request is purely logical/creative/conversational.
   - OR: You have tried multiple searches and cannot find more info (fail gracefully).

4. **REMINDERS (Side Task)**:
   - Extract future tasks into the "reminders" list.

### OUTPUT FORMAT
Return a JSON object (no markdown):
{
  "type": "search" | "draw" | "answer",
  "reason": "[Intent: ...] [Gap: ...] [Strategy: ...]",
  "query": "Search query (optimized for search engine)",
  "content": "Image prompt OR Answer text",
  "reminders": []
}
''';

    final userPrompt = '''
<current_time>
$timeString
</current_time>

<user_profile>
$memoryContent
</user_profile>

<chat_history>
$contextBuffer
</chat_history>

<current_observations>
${refsBuffer.toString()}
</current_observations>

<action_history>
${prevActionsBuffer.toString()}
</action_history>

<user_input>
$userText
</user_input>
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
      ).timeout(const Duration(minutes: 5));

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

    String? currentSessionImagePath;
    List<ReferenceItem> sessionRefs = [];

    // 1. Handle Image Input (Analyze & Prepare)
    if (_selectedImage != null) {
      // Persist the picked image
      currentSessionImagePath = await savePickedImage(_selectedImage!);
      
      setState(() {
        _messages.add(ChatMessage('user', content, localImagePath: currentSessionImagePath));
        _saveChatHistory();
        _inputCtrl.clear();
        _selectedImage = null;
        _sending = true;
        _loadingStatus = '正在分析图片...';
      });
      _scrollToBottom();

      // Analyze the image to produce vision references
      try {
        final visionRefs = await analyzeImage(
          imagePath: currentSessionImagePath,
          baseUrl: _visionBase,
          apiKey: _visionKey,
          model: _visionModel,
        );
        if (visionRefs.isNotEmpty) {
          await _refManager.addExternalReferences(visionRefs);
          sessionRefs.addAll(visionRefs);
        }
      } catch (e) {
        debugPrint('Vision analyze error: $e');
      }
    } else {
      // Text Only Input
      setState(() {
        _messages.add(ChatMessage('user', content));
        _saveChatHistory();
        _inputCtrl.clear();
        _sending = true; 
        _loadingStatus = '正在思考...';
      });
      _scrollToBottom();
    }

    // --- Agent Execution Loop ---
    List<AgentDecision> sessionDecisions = []; // Track decisions in this session
    int steps = 0;
    const int maxSteps = 20; 

    // If content is empty but we have an image, provide a default context for the Agent
    final effectiveUserText = content.isEmpty && currentSessionImagePath != null 
        ? "Please analyze the image I just sent." 
        : content;

    try {
      while (steps < maxSteps) {
        // A. Think (Plan Step)
        setState(() => _loadingStatus = '正在规划下一步 (Step ${steps + 1})...');
        final decision = await _planAgentStep(effectiveUserText, sessionRefs, sessionDecisions);
        sessionDecisions.add(decision); // Record decision
        
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
          
          try {
            final newRefs = await _refManager.search(decision.query!);
            if (newRefs.isNotEmpty) {
              // Deduplicate by URL before adding
              final existingUrls = sessionRefs.map((r) => r.url).toSet();
              final uniqueNewRefs = newRefs.where((r) => !existingUrls.contains(r.url)).toList();
              if (uniqueNewRefs.isNotEmpty) {
                sessionRefs.addAll(uniqueNewRefs);
                debugPrint('Added ${uniqueNewRefs.length} unique refs (${newRefs.length - uniqueNewRefs.length} duplicates skipped)');
              }
              // Continue loop to re-evaluate with new info
            } else {
              // Search returned nothing, force answer to avoid loop
              debugPrint('Search returned no results. Forcing answer.');
              setState(() => _loadingStatus = '搜索无结果，正在生成回答...');
              await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
              break;
            }
          } catch (searchError) {
            // Search failed - graceful degradation: continue with existing refs or answer directly
            debugPrint('Search failed: $searchError. Falling back to answer.');
            setState(() => _loadingStatus = '搜索服务暂时不可用，正在生成回答...');
            await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
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
          await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
          break; // Answer is a terminal action
        }
        
        steps++;
      }
      
      if (steps >= maxSteps) {
        // Fallback if max steps reached
        setState(() => _loadingStatus = '思考步骤过多，正在强制回复...');
        await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
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
      MaterialPageRoute(builder: (context) => SettingsPage(
        onDeepProfile: _performDeepProfiling,
      )),
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
      backgroundColor: const Color(0xFFF2F2F7), // iOS style light grey
      appBar: AppBar(
        title: Column(
          children: [
            const Text('One-API 助手', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text(
              _chatModel,
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
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
                _refManager.clearExternalReferences(); // Clear external refs
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
                      Container(
                        width: 24, height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          image: p.avatarPath != null && File(p.avatarPath!).existsSync()
                              ? DecorationImage(image: FileImage(File(p.avatarPath!)), fit: BoxFit.cover)
                              : null,
                          color: Colors.grey[200],
                        ),
                        child: p.avatarPath == null ? const Icon(Icons.person, size: 16, color: Colors.grey) : null,
                      ),
                      const SizedBox(width: 8),
                      Text(p.name, style: TextStyle(
                        fontWeight: p.id == _currentPersonaId ? FontWeight.bold : FontWeight.normal,
                        color: p.id == _currentPersonaId ? Theme.of(context).primaryColor : null,
                      )),
                      if (p.id == _currentPersonaId) ...[
                        const Spacer(),
                        Icon(Icons.check, size: 16, color: Theme.of(context).primaryColor),
                      ]
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
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // Memory Status Bar
          if (totalChars > 0)
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: double.infinity,
              height: 40, // Always visible if there is content
              color: isMemoryFull ? Colors.red[50] : Colors.grey[100],
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isMemoryFull ? Icons.warning_amber_rounded : Icons.storage_rounded, 
                    size: 16, 
                    color: isMemoryFull ? Colors.red : Colors.grey[600]
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isMemoryFull 
                        ? '记忆库即将爆满 ($totalChars/20000)' 
                        : '当前记忆: $totalChars / 20000 字符',
                    style: TextStyle(
                      fontSize: 12, 
                      color: isMemoryFull ? Colors.red : Colors.grey[800],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (totalChars > 500) // Allow compression if > 500 chars
                    TextButton(
                      onPressed: _sending ? null : _performAdaptiveCompression,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: isMemoryFull ? Colors.red[100] : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: isMemoryFull ? Colors.red[200]! : Colors.grey[300]!)
                        ),
                      ),
                      child: Text(
                        '手动压缩', 
                        style: TextStyle(
                          fontSize: 11, 
                          color: isMemoryFull ? Colors.red : Colors.blue[700]
                        )
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
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, 10))
                            ]
                          ),
                          child: Icon(Icons.chat_bubble_outline_rounded, size: 48, color: Theme.of(context).primaryColor.withOpacity(0.5)),
                        ),
                        const SizedBox(height: 24),
                        Text('开始新的对话吧', style: TextStyle(color: Colors.grey[400], fontSize: 16)),
                        const SizedBox(height: 8),
                        Text('当前人格: ${_activePersona.name}', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => _buildMessageItem(_messages[index]),
                  ),
          ),
          
          // Input Area
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_sending)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 12, height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).primaryColor),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _loadingStatus.isEmpty ? '对方正在输入...' : _loadingStatus,
                            style: TextStyle(fontSize: 12, color: Theme.of(context).primaryColor, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  if (_selectedImage != null)
                    Container(
                      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[200]!),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(File(_selectedImage!.path), width: 48, height: 48, fit: BoxFit.cover),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(child: Text('已选择图片', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20, color: Colors.grey),
                            onPressed: () => setState(() => _selectedImage = null),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          color: Colors.grey[600],
                          onPressed: _sending ? null : _pickImage,
                          tooltip: '发送图片',
                        ),
                        IconButton(
                          icon: const Icon(Icons.palette_outlined),
                          color: Colors.grey[600],
                          onPressed: _sending ? null : _manualGenerateImage,
                          tooltip: 'AI 生图',
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.grey[100],
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: TextField(
                              controller: _inputCtrl,
                              maxLines: 5,
                              minLines: 1,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sending ? null : _send(),
                              decoration: const InputDecoration(
                                hintText: '输入消息...',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                filled: false,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FloatingActionButton(
                          onPressed: _sending ? null : _send,
                          elevation: 0,
                          mini: true,
                          backgroundColor: _sending ? Colors.grey[300] : Theme.of(context).primaryColor,
                          child: Icon(Icons.arrow_upward_rounded, color: _sending ? Colors.grey : Colors.white),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageItem(ChatMessage m) {
    final isUser = m.role == 'user';
    final isSystem = m.role == 'system';

    if (isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            m.content,
            style: TextStyle(fontSize: 11, color: Colors.grey[600], fontWeight: FontWeight.w500),
          ),
        ),
      );
    }

    // Compressed Message UI
    if (m.isCompressed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!isUser) ...[
              _buildAvatar(isUser: false),
              const SizedBox(width: 8),
            ],
            Container(
              width: 200,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.compress, size: 14, color: Colors.grey[600]),
                      const SizedBox(width: 4),
                      Text(
                        '已压缩记忆 (${(m.compressionRatio! * 100).toInt()}%)',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey[600]),
                      ),
                      const Spacer(),
                      Text(
                        '${m.content.length}字',
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: m.compressionRatio,
                    backgroundColor: Colors.grey[300],
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.grey[400]!),
                    minHeight: 2,
                  ),
                ],
              ),
            ),
            if (isUser) ...[
              const SizedBox(width: 8),
              _buildAvatar(isUser: true),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            _buildAvatar(isUser: false),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isUser)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      _activePersona.name,
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isUser ? Theme.of(context).primaryColor : Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isUser ? 18 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 18),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 4,
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
                            borderRadius: BorderRadius.circular(12),
                            child: Builder(
                              builder: (context) {
                                final file = File(m.localImagePath!);
                                if (file.existsSync()) {
                                  return Image.file(file, width: 200, fit: BoxFit.cover);
                                } else {
                                  return Container(
                                    width: 200, height: 100,
                                    color: Colors.grey[300],
                                    child: const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.broken_image, color: Colors.grey),
                                        SizedBox(height: 4),
                                        Text('图片已失效', style: TextStyle(fontSize: 10, color: Colors.grey)),
                                      ],
                                    ),
                                  );
                                }
                              },
                            ),
                          ),
                        ),
                      if (m.imageUrl != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.network(m.imageUrl!, width: 200, fit: BoxFit.cover),
                          ),
                        ),
                      if (m.content.isNotEmpty)
                        MarkdownBody(
                          data: m.content,
                          selectable: true,
                          styleSheet: MarkdownStyleSheet(
                            p: TextStyle(
                              color: isUser ? Colors.white : Colors.black87,
                              fontSize: 15,
                              height: 1.4,
                            ),
                            code: TextStyle(
                              color: isUser ? Colors.white.withOpacity(0.9) : Colors.black87,
                              backgroundColor: isUser ? Colors.white.withOpacity(0.15) : Colors.grey[100],
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                            codeblockDecoration: BoxDecoration(
                              color: isUser ? Colors.black.withOpacity(0.1) : Colors.grey[50],
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: isUser ? Colors.white10 : Colors.grey[200]!),
                            ),
                          ),
                        ),
                      if (m.references != null && m.references!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Theme(
                            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              childrenPadding: EdgeInsets.zero,
                              iconColor: isUser ? Colors.white70 : Colors.grey[400],
                              collapsedIconColor: isUser ? Colors.white70 : Colors.grey[400],
                              title: Row(
                                children: [
                                  Icon(Icons.link, size: 14, color: isUser ? Colors.white70 : Colors.grey[500]),
                                  const SizedBox(width: 4),
                                  Text(
                                    '参考资料 (${m.references!.length})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: isUser ? Colors.white70 : Colors.grey[500],
                                    ),
                                  ),
                                ],
                              ),
                              children: m.references!.map((ref) => InkWell(
                                onTap: () {
                                  if (ref.url.isNotEmpty) {
                                    Clipboard.setData(ClipboardData(text: ref.url));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('链接已复制: ${ref.url}'),
                                        duration: const Duration(seconds: 1),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  }
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: isUser ? Colors.white.withOpacity(0.1) : Colors.grey[50],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        ref.title,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isUser ? Colors.white : Colors.black87,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        ref.snippet,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isUser ? Colors.white70 : Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )).toList(),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            _buildAvatar(isUser: true),
          ],
        ],
      ),
    );
  }

  Widget _buildAvatar({required bool isUser}) {
    if (isUser) {
      return Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.person, size: 20, color: Theme.of(context).primaryColor),
      );
    } else {
      final avatarPath = _activePersona.avatarPath;
      final hasAvatar = avatarPath != null && File(avatarPath).existsSync();
      
      return Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          image: hasAvatar 
              ? DecorationImage(image: FileImage(File(avatarPath)), fit: BoxFit.cover)
              : null,
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2)),
          ],
        ),
        child: !hasAvatar 
            ? Center(child: Text(_activePersona.name.isNotEmpty ? _activePersona.name[0] : '?', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)))
            : null,
      );
    }
  }
}
