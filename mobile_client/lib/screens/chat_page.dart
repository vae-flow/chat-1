import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
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
import '../services/file_saver.dart';
import '../services/system_control.dart';
import '../services/knowledge_service.dart';
import '../utils/constants.dart';
import 'package:file_picker/file_picker.dart';
import 'settings_page.dart';
import 'persona_manager_page.dart';
import '../main.dart';  // For AppColors
import 'dart:math' as math;
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

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

// Inline/Block math support for Markdown rendering
class BlockMathSyntax extends md.InlineSyntax {
  BlockMathSyntax() : super(r'\$\$([^$]+?)\$\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('block_math', match[1]!));
    return true;
  }
}

class InlineMathSyntax extends md.InlineSyntax {
  InlineMathSyntax() : super(r'\$([^$\n]+?)\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('inline_math', match[1]!));
    return true;
  }
}

class MathBuilder extends MarkdownElementBuilder {
  MathBuilder({required this.isBlock});

  final bool isBlock;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final formula = element.textContent.trim();
    if (formula.isEmpty) return const SizedBox.shrink();

    final mathWidget = Math.tex(
      formula,
      mathStyle: MathStyle.text,
      textStyle: preferredStyle,
      textScaleFactor: isBlock ? 1.05 : 1.0,
    );

    return isBlock
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: mathWidget,
          )
        : mathWidget;
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  final TextEditingController _inputCtrl = TextEditingController();
  
  // 动画控制器
  late AnimationController _pulseController;
  late AnimationController _floatController;
  late AnimationController _loadingDotsController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _floatAnimation;
  final ScrollController _scrollCtrl = ScrollController();
  final ImagePicker _picker = ImagePicker();
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final ReferenceManager _refManager = ReferenceManager();
  final KnowledgeService _knowledgeService = KnowledgeService();
  
  bool _sending = false;
  String _loadingStatus = ''; // To show detailed agent status
  final List<ChatMessage> _messages = [];
  XFile? _selectedImage;
  
  // Deep Think: Pending clarification state
  Map<String, dynamic>? _pendingClarification;

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
    _initAnimations();
    _initNotifications();
    _loadSettings();
    _loadPersonas().then((_) {
      // Initialize knowledge base with current persona after personas are loaded
      _knowledgeService.init();
      _knowledgeService.setPersona(_currentPersonaId);
    });
    _loadChatHistory();
  }
  
  void _initAnimations() {
    // 脉冲动画 - 用于空状态图标
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    // 浮动动画 - 用于空状态
    _floatController = AnimationController(
      duration: const Duration(milliseconds: 3000),
      vsync: this,
    )..repeat(reverse: true);
    _floatAnimation = Tween<double>(begin: -8, end: 8).animate(
      CurvedAnimation(parent: _floatController, curve: Curves.easeInOut),
    );
    
    // 加载动画控制器
    _loadingDotsController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }
  
  @override
  void dispose() {
    _pulseController.dispose();
    _floatController.dispose();
    _loadingDotsController.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
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
    
    // 3. Switch knowledge base to new persona
    await _knowledgeService.setPersona(id);
    
    // 4. Persist the switch
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
      
      // 3. Restore Pending Clarification State (for session recovery)
      final pendingStr = prefs.getString('pending_clarification_$_currentPersonaId');
      if (pendingStr != null && pendingStr.isNotEmpty) {
        try {
          _pendingClarification = json.decode(pendingStr) as Map<String, dynamic>;
          debugPrint('Restored pending clarification state');
        } catch (e) {
          debugPrint('Failed to restore pending clarification: $e');
          _pendingClarification = null;
        }
      }
      
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
  String? _lastCompressionNote;

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
      
      // 3. Save Pending Clarification State (for session recovery)
      if (_pendingClarification != null) {
        await prefs.setString('pending_clarification_$_currentPersonaId', json.encode(_pendingClarification));
      } else {
        await prefs.remove('pending_clarification_$_currentPersonaId');
      }
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

  Future<void> _pickAndIngestFile() async {
    // Ensure knowledge base is initialized for current persona
    if (_knowledgeService.currentPersonaId != _currentPersonaId) {
      await _knowledgeService.setPersona(_currentPersonaId);
    }
    
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          // Text & Documents
          'txt', 'md', 'markdown', 'rst', 'log', 'csv', 'tsv',
          // Code - Common
          'json', 'xml', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf',
          // Code - Web
          'html', 'htm', 'css', 'scss', 'sass', 'less', 'js', 'jsx', 'ts', 'tsx', 'vue', 'svelte',
          // Code - Backend
          'py', 'pyw', 'pyi', 'java', 'kt', 'kts', 'scala', 'groovy', 'go', 'rs', 'rb', 'php',
          // Code - Systems
          'c', 'cpp', 'cc', 'cxx', 'h', 'hpp', 'hxx', 'cs', 'fs', 'fsx',
          // Code - Mobile
          'swift', 'dart', 'm', 'mm',
          // Code - Shell & Scripts
          'sh', 'bash', 'zsh', 'fish', 'ps1', 'psm1', 'bat', 'cmd',
          // Code - Data & Query
          'sql', 'graphql', 'gql',
          // Code - Functional
          'hs', 'lhs', 'elm', 'clj', 'cljs', 'erl', 'ex', 'exs',
          // Code - Other
          'lua', 'r', 'pl', 'pm', 'tcl', 'awk', 'sed', 'vim',
          // Markup & Config
          'tex', 'bib', 'sty', 'cls',
          // Data formats
          'ndjson', 'jsonl', 'geojson',
        ],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final filename = result.files.single.name;
        
        // Check size (limit to 10MB for text files)
        final size = await file.length();
        if (size > 10 * 1024 * 1024) {
          _showError('文件过大 (限制10MB)');
          return;
        }

        setState(() {
          _sending = true;
          _loadingStatus = '正在读取并索引文件...';
        });

        try {
          // Try to read as UTF-8, fallback to Latin1 if fails
          String content;
          try {
            content = await file.readAsString(encoding: utf8);
          } catch (e) {
            // Fallback for non-UTF8 files
            final bytes = await file.readAsBytes();
            content = latin1.decode(bytes);
          }
          
          await _knowledgeService.ingestFile(
            filename: filename,
            content: content,
            summarizer: (chunk) => _generateKnowledgeSummary(chunk, filename), // File-type aware summary
          );

          // Get stats for user feedback
          final stats = _knowledgeService.getStats();
          final fileInfo = _knowledgeService.files.where((f) => f.filename == filename).lastOrNull;
          final chunkCount = fileInfo?.chunks.length ?? 0;
          
          setState(() {
            _messages.add(ChatMessage('system', 
              '✅ 文件 "$filename" 已成功索引到知识库。\n'
              '📊 共切分为 $chunkCount 个知识块\n'
              '📚 知识库现有 ${stats['fileCount']} 个文件，${stats['chunkCount']} 个知识块\n'
              '💡 现在您可以询问关于该文件的内容了。', 
              isMemory: true));
            _saveChatHistory();
          });
          
          _showSuccessSnackBar('文件索引完成 ($chunkCount 块)');
        } catch (e) {
          _showError('处理文件失败: $e');
        } finally {
          setState(() {
            _sending = false;
            _loadingStatus = '';
          });
        }
      }
    } catch (e) {
      _showError('选择文件失败: $e');
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

  /// Returns the local path of the generated image on success, null on failure
  Future<String?> _performImageGeneration(String prompt, {bool addUserMessage = true, bool manageSendingState = true}) async {
    if (_imgBase.contains('your-oneapi-host') || _imgKey.isEmpty) {
      _showError('请先配置生图 API');
      _openSettings();
      return null;
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
        _messages.add(ChatMessage('assistant', '图片生成成功\n$prompt', localImagePath: localPath));
        _saveChatHistory();
      });
      _scrollToBottom();
      
      return localPath; // Return path for tool chaining

    } catch (e) {
      _showError('生图异常：$e');
      return null;
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

  /// Compress a history list into system summaries before发送给大模型，保持顺序与上限控制
  Future<List<ChatMessage>> _compressHistoryForTransport(
    List<ChatMessage> history, {
    required int targetChars,
    int keepTail = 4,
    int depth = 0,
  }) async {
    int total = history.fold(0, (p, c) => p + c.content.length);
    if (total <= targetChars) {
      if (depth == 0) _lastCompressionNote = null;
      return history;
    }

    // Keep the most recent messages intact
    keepTail = keepTail.clamp(2, history.length).toInt();
    final tail = history.sublist(history.length - keepTail);
    final older = history.sublist(0, history.length - keepTail);

    // Flatten older messages into chunks
    const int chunkSize = 8000;
    final List<String> chunkStrings = [];
    final buffer = StringBuffer();
    for (final m in older) {
      buffer.writeln('${m.role}: ${m.content}');
      if (buffer.length >= chunkSize) {
        chunkStrings.add(buffer.toString());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) {
      chunkStrings.add(buffer.toString());
    }

    if (chunkStrings.isEmpty) return history;

    final totalOlderLen = chunkStrings.fold(0, (p, c) => p + c.length);
    if (totalOlderLen == 0) return history;
    // Desired ratio so that compressed older + tail ~= targetChars
    final desiredRatio = (targetChars * 0.9) / totalOlderLen;
    final double ratio = desiredRatio.clamp(0.2, 0.7).toDouble();

    final compressedMsgs = <ChatMessage>[];
    for (int i = 0; i < chunkStrings.length; i++) {
      final summary = await _generateSummary(chunkStrings[i], ratio);
      compressedMsgs.add(
        ChatMessage(
          'system',
          '【压缩摘要 #${i + 1}/${chunkStrings.length} | ratio ${(ratio * 100).toInt()}%】\n$summary',
          isMemory: true,
          isCompressed: true,
          compressionRatio: ratio,
          originalLength: chunkStrings[i].length,
        ),
      );
    }

    final merged = [...compressedMsgs, ...tail];
    final mergedLen = merged.fold(0, (p, c) => p + c.content.length);

    if (depth == 0) {
      _lastCompressionNote =
          '【压缩提示】上下文超限，已将早期消息分块压缩为 ${chunkStrings.length} 条摘要，压缩比约 ${(ratio * 100).toInt()}%，保留最近 $keepTail 条原文；可能有细节缺失，如需细节请明确指出。';
    }

    // If still too long, do one more pass with a slightly tighter ratio
    if (mergedLen > targetChars && compressedMsgs.isNotEmpty && depth < 2) {
      final tighterTarget = (targetChars * 0.8).toInt();
      return _compressHistoryForTransport(
        merged,
        targetChars: tighterTarget,
        keepTail: keepTail,
        depth: depth + 1,
      );
    }

    return merged;
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

【对话透明度】
- 若你感到上下文被压缩、信息缺失或需要用户补充，请直接在回复里说明缺口并提出具体问题。
- 工具性调用（搜索/生图/识图）无需赘述细节，但请在最终回答中提示哪些部分依赖了这些工具或因未配置而缺失。
- 如果已有系统提示说明“压缩/缺少信息”，请结合该提示，继续追问关键细节而不是沉默。
''';

    if (manageSendingState) {
      setState(() {
        _sending = true;
      });
    }
    _scrollToBottom();

    try {
      // Normalize URL - only remove trailing slashes, respect user's path configuration
      String cleanBase = apiBase.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$cleanBase/chat/completions');
      
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

        // Enforce Context Limit using worker压缩，多次调用 summary 模型，保留尾部原文
        const int chatContextCap = 60000;
        if (historyToUse.fold(0, (sum, m) => sum + m.content.length) > chatContextCap) {
          if (manageSendingState) {
            setState(() => _loadingStatus = '上下文过长，正在分块压缩...');
          }
          historyToUse = await _compressHistoryForTransport(
            historyToUse,
            targetChars: chatContextCap,
            keepTail: 6,
          );
        }

        final compressionNote = _lastCompressionNote;
        _lastCompressionNote = null; // reset

        messagesPayload = [
          {'role': 'system', 'content': timeAwareSystemPrompt},
          if (compressionNote != null)
            {'role': 'system', 'content': compressionNote},
          ...historyToUse.map((m) {
            String msgContent = m.content;
            if (msgContent.isEmpty && (m.imageUrl != null || m.localImagePath != null)) {
              msgContent = "[图片]";
            }
            return {'role': m.role, 'content': msgContent};
          }).where((m) => m['content'].toString().isNotEmpty)
        ];

        if (compressionNote != null && manageSendingState) {
          _showError(compressionNote);
        }
      }

      final body = json.encode({
        'model': model,
        'messages': messagesPayload,
        'stream': _enableStream,
        'max_tokens': 60000,
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
          String? finishReason;
          await for (final line in streamedResponse.stream.transform(utf8.decoder).transform(const LineSplitter())) {
            if (line.startsWith('data: ')) {
              final data = line.substring(6).trim();
              if (data == '[DONE]') break;
              try {
                final jsonVal = json.decode(data);
                final delta = jsonVal['choices']?[0]?['delta']?['content'];
                finishReason = jsonVal['choices']?[0]?['finish_reason'] ?? finishReason;
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
          // Check if output was truncated due to token limit
          if (finishReason == 'length') {
            _showError('⚠️ 输出被服务端截断 (finish_reason: length)，回复可能不完整');
          }
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
          final finishReason = data['choices']?[0]?['finish_reason'];
          setState(() {
            _messages.add(ChatMessage(
              'assistant', 
              reply.toString(),
              references: references, // Pass references to UI
            ));
            _saveChatHistory();
          });
          _scrollToBottom();
          
          // Check if output was truncated
          if (finishReason == 'length') {
            _showError('⚠️ 输出被服务端截断 (finish_reason: length)，回复可能不完整');
          }
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

  /// Get Worker API config with fallback chain: Worker -> Worker Pro -> Router -> Chat
  Future<({String base, String key, String model})> _getWorkerConfig() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Helper to check if URL is valid (not placeholder)
    bool isValidUrl(String url) {
      return url.isNotEmpty && 
             !url.contains('your-oneapi-host') && 
             !url.contains('your-api-host');
    }
    
    // Get user's configured chat model as ultimate fallback
    final userChatModel = prefs.getString('chat_model') ?? '';
    
    // Try Worker first (execution tasks)
    final workerBase = prefs.getString('worker_base') ?? '';
    final workerKeys = prefs.getString('worker_keys') ?? '';
    final workerModel = prefs.getString('worker_model') ?? '';
    
    if (isValidUrl(workerBase) && workerKeys.isNotEmpty) {
      final firstKey = workerKeys.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).firstOrNull ?? '';
      if (firstKey.isNotEmpty) {
        // Use configured model, or fallback to user's chat model
        return (base: workerBase, key: firstKey, model: workerModel.isNotEmpty ? workerModel : (userChatModel.isNotEmpty ? userChatModel : 'gpt-4o-mini'));
      }
    }
    
    // Try Worker Pro (thinking tasks like summarization)
    final workerProBase = prefs.getString('worker_pro_base') ?? '';
    final workerProKeys = prefs.getString('worker_pro_keys') ?? '';
    final workerProModel = prefs.getString('worker_pro_model') ?? '';
    
    if (isValidUrl(workerProBase) && workerProKeys.isNotEmpty) {
      final firstKey = workerProKeys.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).firstOrNull ?? '';
      if (firstKey.isNotEmpty) {
        return (base: workerProBase, key: firstKey, model: workerProModel.isNotEmpty ? workerProModel : (userChatModel.isNotEmpty ? userChatModel : 'gpt-4o-mini'));
      }
    }
    
    // Fallback to Router API
    if (isValidUrl(_routerBase) && _routerKey.isNotEmpty) {
      return (base: _routerBase, key: _routerKey, model: _routerModel.isNotEmpty ? _routerModel : (userChatModel.isNotEmpty ? userChatModel : 'gpt-4o-mini'));
    }
    
    // Final fallback to Chat API
    final effectiveBase = isValidUrl(_chatBase) ? _chatBase : 'https://api.openai.com/v1';
    return (base: effectiveBase, key: _chatKey, model: _summaryModel.isNotEmpty ? _summaryModel : (userChatModel.isNotEmpty ? userChatModel : 'gpt-4o-mini'));
  }

  Future<String> _generateSummary(String text, double ratio) async {
    // Use Worker config with fallback chain
    final config = await _getWorkerConfig();
    final double effectiveRatio = ratio.clamp(0.2, 0.7).toDouble();
    
    final prompt = '''
Please summarize the following text to retain approximately ${(effectiveRatio * 100).toInt()}% of the original information density (never compress beyond 20%).
Focus on key facts, decisions, and order of events.
Original Text:
$text
''';

    try {
      // Normalize base URL - only remove trailing slashes, respect user's path
      String apiEndpoint = config.base.replaceAll(RegExp(r'/+$'), '');
      apiEndpoint = '$apiEndpoint/chat/completions';
      
      final uri = Uri.parse(apiEndpoint);
      final body = json.encode({
        'model': config.model,
        'messages': [
          {'role': 'system', 'content': 'You are a concise summarizer.'},
          {'role': 'user', 'content': prompt}
        ],
        'stream': false,
      });

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${config.key}',
          'Content-Type': 'application/json',
        },
        body: body,
      ).timeout(const Duration(minutes: 5));

      if (resp.statusCode == 200) {
        final decodedBody = utf8.decode(resp.bodyBytes);
        final data = json.decode(decodedBody);
        return data['choices'][0]['message']['content'] ?? text;
      } else {
        debugPrint('Summary API error: ${resp.statusCode} - ${resp.body}');
      }
    } catch (e) {
      debugPrint('Summary failed: $e');
    }
    return text; // Fallback
  }

  /// Generate file-type aware summary for knowledge base indexing
  Future<String> _generateKnowledgeSummary(String chunk, String filename) async {
    final config = await _getWorkerConfig();
    final ext = filename.toLowerCase().split('.').last;
    
    // Determine file type and appropriate prompt
    String typeHint;
    String extractionFocus;
    
    // Code files
    if (['dart', 'py', 'js', 'ts', 'jsx', 'tsx', 'java', 'kt', 'swift', 'go', 'rs', 'rb', 'php', 'c', 'cpp', 'cs', 'scala'].contains(ext)) {
      typeHint = 'This is SOURCE CODE';
      extractionFocus = '''Extract and list:
1. Class/Function/Method names with their purpose (one line each)
2. Key imports/dependencies
3. Main logic flow or algorithm summary
4. Important variables/constants
Format: Use bullet points. Be technical and precise.''';
    }
    // Config/Data files
    else if (['json', 'yaml', 'yml', 'toml', 'xml', 'ini', 'cfg', 'conf'].contains(ext)) {
      typeHint = 'This is a CONFIGURATION/DATA file';
      extractionFocus = '''Extract and list:
1. Top-level keys/sections
2. Important configuration values
3. Data structure overview
4. Any URLs, paths, or credentials (redact sensitive values)
Format: Hierarchical bullet points showing structure.''';
    }
    // Documentation/Text
    else if (['md', 'markdown', 'rst', 'txt', 'log'].contains(ext)) {
      typeHint = 'This is DOCUMENTATION/TEXT';
      extractionFocus = '''Extract and list:
1. Main topics/headings
2. Key concepts or definitions
3. Important conclusions or action items
4. Any code examples or commands mentioned
Format: Concise bullet points preserving key information.''';
    }
    // Data files
    else if (['csv', 'tsv', 'ndjson', 'jsonl'].contains(ext)) {
      typeHint = 'This is TABULAR/STRUCTURED DATA';
      extractionFocus = '''Extract and list:
1. Column names/field names
2. Data types for each column
3. Sample values (first 2-3 rows)
4. Total approximate row count if visible
Format: Table-like description.''';
    }
    // SQL/Query
    else if (['sql', 'graphql', 'gql'].contains(ext)) {
      typeHint = 'This is DATABASE/QUERY code';
      extractionFocus = '''Extract and list:
1. Table/Collection names involved
2. Query types (SELECT, INSERT, CREATE, etc.)
3. Key conditions/filters
4. Joins or relationships
Format: Technical bullet points.''';
    }
    // Web files
    else if (['html', 'htm', 'vue', 'svelte'].contains(ext)) {
      typeHint = 'This is WEB MARKUP/COMPONENT';
      extractionFocus = '''Extract and list:
1. Page/Component structure
2. Key elements (forms, buttons, sections)
3. Any embedded scripts or styles
4. Data bindings or props
Format: Structural outline.''';
    }
    // Shell/Scripts
    else if (['sh', 'bash', 'ps1', 'bat', 'cmd'].contains(ext)) {
      typeHint = 'This is a SHELL SCRIPT';
      extractionFocus = '''Extract and list:
1. Main commands being executed
2. Variables and their purposes
3. Control flow (if/else, loops)
4. File/directory operations
Format: Step-by-step summary.''';
    }
    // Default
    else {
      typeHint = 'This is a TEXT file';
      extractionFocus = '''Summarize the key content:
1. Main topics covered
2. Important facts or data
3. Any structured information
Format: Concise bullet points.''';
    }
    
    final prompt = '''$typeHint (.$ext file)

TASK: Create a searchable index summary for this content chunk.
The summary will be used to help an AI assistant find relevant information later.

$extractionFocus

CONTENT:
$chunk

OUTPUT REQUIREMENTS:
- Maximum 300 words
- Use keywords that would help find this content
- Be specific, not vague
- Chinese response preferred if content is Chinese''';

    try {
      String apiEndpoint = config.base.replaceAll(RegExp(r'/+$'), '');
      apiEndpoint = '$apiEndpoint/chat/completions';
      
      final uri = Uri.parse(apiEndpoint);
      final body = json.encode({
        'model': config.model,
        'messages': [
          {'role': 'system', 'content': 'You are an expert at creating searchable index summaries for code and documents. Be concise but comprehensive.'},
          {'role': 'user', 'content': prompt}
        ],
        'temperature': 0.3,
        'stream': false,
      });

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${config.key}',
          'Content-Type': 'application/json',
        },
        body: body,
      ).timeout(const Duration(minutes: 3));

      if (resp.statusCode == 200) {
        final decodedBody = utf8.decode(resp.bodyBytes);
        final data = json.decode(decodedBody);
        return data['choices'][0]['message']['content'] ?? _fallbackSummary(chunk, ext);
      } else {
        debugPrint('Knowledge summary API error: ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('Knowledge summary failed: $e');
    }
    return _fallbackSummary(chunk, ext);
  }

  /// Fallback summary when API fails - extract key patterns
  String _fallbackSummary(String chunk, String ext) {
    final lines = chunk.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final buffer = StringBuffer();
    buffer.writeln('[Fallback Summary - API unavailable]');
    
    // For code: extract function/class definitions
    if (['dart', 'py', 'js', 'ts', 'java', 'kt', 'go', 'rs'].contains(ext)) {
      final patterns = [
        RegExp(r'(class|interface|enum)\s+(\w+)'),
        RegExp(r'(def|func|function|fn)\s+(\w+)'),
        RegExp(r'(public|private|async)?\s*(static)?\s*\w+\s+(\w+)\s*\('),
      ];
      final matches = <String>{};
      for (var line in lines.take(50)) {
        for (var pattern in patterns) {
          final match = pattern.firstMatch(line);
          if (match != null) {
            matches.add(line.trim().substring(0, line.trim().length.clamp(0, 80)));
          }
        }
      }
      if (matches.isNotEmpty) {
        buffer.writeln('Definitions found:');
        for (var m in matches.take(10)) {
          buffer.writeln('  - $m');
        }
      }
    }
    
    // Show first few meaningful lines
    buffer.writeln('Content preview:');
    for (var line in lines.take(5)) {
      final trimmed = line.trim();
      if (trimmed.length > 100) {
        buffer.writeln('  ${trimmed.substring(0, 100)}...');
      } else {
        buffer.writeln('  $trimmed');
      }
    }
    
    return buffer.toString();
  }

  Future<void> _performDeepProfiling() async {
    if (_profileBase.contains('your-oneapi-host') || _profileKey.isEmpty) {
      _showError('请先在设置中配置 Profiler API');
      _openSettings();
      return;
    }

    // Use a notifier to update a modal progress dialog so the UI doesn't appear to "hang".
    final ValueNotifier<String> progress = ValueNotifier<String>('🔮 准备读取历史记录...');
    final ValueNotifier<double> progressValue = ValueNotifier<double>(0.0);
    final ValueNotifier<String> funFact = ValueNotifier<String>('');

    // Fun facts to display during profiling
    final funFacts = [
      '💡 正在分析你的思维模式...',
      '🎨 探索你的审美偏好...',
      '🧠 解码你的决策风格...',
      '❤️ 感知你的情感特征...',
      '🎯 理解你的目标与追求...',
      '🔍 发现隐藏的行为规律...',
      '✨ 构建专属于你的画像...',
      '🌟 每一次对话都让我更懂你...',
    ];
    int factIndex = 0;

    // Rotate fun facts
    Timer? factTimer;
    factTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      factIndex = (factIndex + 1) % funFacts.length;
      funFact.value = funFacts[factIndex];
    });
    funFact.value = funFacts[0];

    if (!mounted) return;

    // Show non-dismissible progress dialog with enhanced UI
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated gradient icon
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryStart.withOpacity(0.4),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.psychology_rounded, size: 40, color: Colors.white),
                ),
                const SizedBox(height: 20),
                // Title
                const Text(
                  '深度刻画进行中',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                // Fun fact with animation
                ValueListenableBuilder<String>(
                  valueListenable: funFact,
                  builder: (context, fact, _) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    child: Text(
                      fact,
                      key: ValueKey(fact),
                      style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Progress bar
                ValueListenableBuilder<double>(
                  valueListenable: progressValue,
                  builder: (context, value, _) => Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: value > 0 ? value : null,
                          minHeight: 8,
                          backgroundColor: Colors.grey[200],
                          valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primaryStart),
                        ),
                      ),
                      if (value > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          '${(value * 100).toInt()}%',
                          style: TextStyle(fontSize: 12, color: Colors.grey[500], fontWeight: FontWeight.w500),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Status text
                ValueListenableBuilder<String>(
                  valueListenable: progress,
                  builder: (context, value, _) => Text(
                    value, 
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
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
      progressValue.value = 0.05;

      // 1. Gather ALL History (Archive + Active)
      final dir = await getApplicationDocumentsDirectory();
      final archivePath = '${dir.path}/chat_archive.jsonl';
      final allHistoryBuffer = StringBuffer();

      // Read Archive in Isolate (non-blocking) with error handling
      progress.value = '📚 读取归档记录...';
      progressValue.value = 0.1;
      debugPrint('Reading archive from $archivePath');
      String archiveContent = '';
      try {
        archiveContent = await compute(_processHistoryInIsolate, archivePath)
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        debugPrint('Archive read failed (non-fatal): $e');
        // Continue without archive - not fatal
      }
      allHistoryBuffer.write(archiveContent);
      debugPrint('Archive read complete, length: ${archiveContent.length}');
      progressValue.value = 0.2;

      // Add unarchived active messages
      progress.value = '💬 合并当前会话消息...';
      for (var m in _messages) {
        if (!m.isArchived) {
          allHistoryBuffer.writeln('[${_activePersona.id}] ${m.role}: ${m.content}');
        }
      }

      final fullText = allHistoryBuffer.toString();
      if (fullText.isEmpty) {
        progress.value = '⚠️ 无足够历史记录';
        _showError('没有足够的历史记录进行刻画');
        setState(() {
          _loadingStatus = '';
          _sending = false;
        });
        factTimer?.cancel();
        return;
      }

      // 2. Chunking (Safe limit: 10000 chars to avoid token limits)
      const int chunkSize = 10000;
      final chunks = <String>[];
      for (int i = 0; i < fullText.length; i += chunkSize) {
        int end = (i + chunkSize < fullText.length) ? i + chunkSize : fullText.length;
        chunks.add(fullText.substring(i, end));
      }
      progressValue.value = 0.25;

      // Gather user-initiated content only (NOT search results - those are already processed by AI)
      // Focus on: user-uploaded images analysis, user's creative requests
      progress.value = '🖼️ 收集用户主动分享内容...';
      final refsHistoryBuffer = StringBuffer();
      
      // Get stored references from reference manager
      final allRefs = await _refManager.getAllStoredReferences();
      if (allRefs.isNotEmpty) {
        // Only user-initiated content: vision (user uploaded images) and generated (user's creative intent)
        // Skip search refs - they are raw materials already processed into conversation
        final visionRefs = allRefs.where((r) => r.sourceType == 'vision').toList();
        final generatedRefs = allRefs.where((r) => r.sourceType == 'generated').toList();
        
        if (visionRefs.isNotEmpty) {
          refsHistoryBuffer.writeln('【用户上传图片分析 - ${visionRefs.length}次】');
          refsHistoryBuffer.writeln('（用户主动分享的图片反映其关注点和审美）');
          for (var r in visionRefs.take(15)) {
            final snippet = r.snippet.length > 150 ? '${r.snippet.substring(0, 150)}...' : r.snippet;
            refsHistoryBuffer.writeln('- $snippet');
          }
        }
        if (generatedRefs.isNotEmpty) {
          refsHistoryBuffer.writeln('\n【用户创作请求 - ${generatedRefs.length}次】');
          refsHistoryBuffer.writeln('（用户的生图请求反映其创意需求和审美取向）');
          for (var r in generatedRefs.take(15)) {
            refsHistoryBuffer.writeln('- ${r.snippet}');
          }
        }
      }
      final refsHistory = refsHistoryBuffer.toString();
      progressValue.value = 0.3;

      String currentProfile = _globalMemoryCache;

      // 3. PHASE 1: Deep Conversation Analysis (chunked)
      progress.value = '🧠 第一阶段：对话深度分析...';
      final totalChunks = chunks.length;
      for (int i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        final chunkProgress = 0.3 + (0.65 * (i + 1) / totalChunks);
        progressValue.value = chunkProgress;
        final statusText = '🔍 深度刻画中... (${i + 1}/$totalChunks)';
        progress.value = statusText;
        setState(() => _loadingStatus = statusText);

        // Include refs history only in the first chunk to provide full context
        final refsContext = (i == 0 && refsHistory.isNotEmpty) 
            ? '\n\n【用户行为足迹 - 搜索/视觉/创作历史】：\n$refsHistory\n' 
            : '';

        // Build prompt with multi-dimensional profiling framework
        final prompt = '''
【首席用户侧写师 - 核心使命】
你的唯一目标是"完全理解这个用户"。通过用户的一切直接痕迹，构建一份能让任何AI瞬间理解这个人的完整画像。

═══════════════════════════════════════════════════════════
【最核心输入：当前用户画像】（严禁信息丢失！）
═══════════════════════════════════════════════════════════
$currentProfile
═══════════════════════════════════════════════════════════

【重要性说明】
上述【当前用户画像】是之前所有对话和刻画的结晶，代表对用户的累积理解。
⚠️ 严禁直接覆盖！必须在此基础上扩展、深化、精炼。
⚠️ 已有维度必须保留！可以新增维度，但不能删除任何已存在的分析维度。

═══════════════════════════════════════════════════════════
【本轮分析素材】（第 ${i + 1}/${chunks.length} 部分）
═══════════════════════════════════════════════════════════
【用户直接对话内容】：
$chunk

【用户主动分享的内容】（如有）：
$refsContext
═══════════════════════════════════════════════════════════

【动态维度发现机制】
不要使用固定的分析框架！请根据用户的实际内容，自主发现并构建最适合这个用户的分析维度。

思考路径：
1. 这个用户在对话中展现了哪些独特特征？
2. 现有画像中有哪些维度？必须全部保留并深化
3. 本轮对话揭示了哪些新的维度？应该新增
4. 不同信息之间有什么关联和矛盾？
5. 表面信息背后隐藏着什么深层洞察？

可能的维度方向（仅供参考，请自主扩展）：
- 认知与思维模式
- 情感与价值观
- 行为与习惯
- 知识与技能
- 社交与人际
- 需求与期望
- 性格与特质
- 目标与追求
- 痛点与困扰
- 表达风格
- 决策偏好
- 时间感知
- 审美取向
- 生活状态
- ...（请根据用户特点自由扩展）

【核心指令】
1. 【严格继承】当前画像中的所有维度和核心信息必须保留
2. 【增量更新】在继承基础上融合本轮新发现
3. 【维度扩展】发现新维度时直接新增，永不删除旧维度
4. 【深度挖掘】透过现象看本质，推断隐含信息
5. 【矛盾标注】发现与现有画像矛盾时，标注并分析原因
6. 【信息溯源】新增信息时可注明来源（如"从本轮对话推断"）

【输出要求】
直接输出完整的用户画像，使用清晰的结构化格式。
无需任何元评论或解释。
字数不限，越详细越好，但请保持条理清晰。
''';

        // Normalize URL - only remove trailing slashes, respect user's path
        String cleanProfileBase = _profileBase.replaceAll(RegExp(r'/+$'), '');
        final uri = Uri.parse('$cleanProfileBase/chat/completions');
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

      // 4. Final Save with celebration
      progressValue.value = 1.0;
      progress.value = '✨ 画像构建完成！';
      await Future.delayed(const Duration(milliseconds: 500));
      
      setState(() {
        _globalMemoryCache = currentProfile;
        _saveChatHistory();
        _loadingStatus = '';
        _sending = false;
      });
      
      // Show success with confetti-style message
      _showSuccessSnackBar('🎉 深度刻画完成！我更懂你了~');
    } catch (e) {
      debugPrint('Deep profiling exception: $e');
      _showError('刻画失败: $e');
      setState(() {
        _loadingStatus = '';
        _sending = false;
      });
    } finally {
      // Clean up timer
      factTimer?.cancel();
      
      if (mounted) {
        try {
          await Navigator.of(context, rootNavigator: true).maybePop();
        } catch (_) {}
      }
      try {
        progress.dispose();
        progressValue.dispose();
        funFact.dispose();
      } catch (_) {}
    }
  }

  /// Use Worker API to semantically parse natural language into a structured AgentDecision
  /// This is smarter than regex because it understands meaning, not just keywords
  Future<AgentDecision?> _parseIntentWithWorker(String rawResponse) async {
    // Get Worker API config
    final prefs = await SharedPreferences.getInstance();
    String workerBase = prefs.getString('worker_base') ?? '';
    String workerKeys = prefs.getString('worker_keys') ?? '';
    String workerModel = prefs.getString('worker_model') ?? 'gpt-3.5-turbo';
    
    // Fallback to chat API if worker not configured
    if (workerBase.isEmpty || workerKeys.isEmpty) {
      workerBase = _chatBase;
      workerKeys = _chatKey;
      workerModel = _chatModel;
    }
    
    // Pick a random key if multiple
    final keyList = workerKeys.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    if (keyList.isEmpty) return null;
    final selectedKey = keyList[DateTime.now().millisecond % keyList.length];
    
    // Super simple prompt for intent extraction
    const systemPrompt = '''You are an intent parser. Given text that describes an action, output ONLY a JSON object.

Available types: search, read_url, draw, vision, save_file, system_control, search_knowledge, read_knowledge, delete_knowledge, take_note, reflect, hypothesize, clarify, answer

Examples:
Input: "我觉得需要去网上查一下最新价格"
Output: {"type":"search","query":"最新价格","continue":true}

Input: "让我仔细看看这个网页的内容"
Output: {"type":"read_url","content":"https://example.com","continue":true}

Input: "帮用户画一张日落的图"
Output: {"type":"draw","content":"beautiful sunset, warm colors","continue":false}

Input: "分析一下这张图片里有什么"
Output: {"type":"vision","content":"请详细描述图片内容","continue":true}

Input: "把这段代码保存下来"
Output: {"type":"save_file","filename":"code.txt","content":"代码内容","continue":false}

Input: "回到主屏幕"
Output: {"type":"system_control","content":"home","continue":false}

Input: "在知识库里搜索关于Python的内容"
Output: {"type":"search_knowledge","content":"Python","continue":true}

Input: "读取知识块chunk_001的内容"
Output: {"type":"read_knowledge","content":"chunk_001","continue":true}

Input: "删除这个知识文件"
Output: {"type":"delete_knowledge","content":"file_id","continue":false}

Input: "记下来这个重要信息"
Output: {"type":"take_note","content":"重要信息内容","continue":true}

Input: "需要仔细想想这个问题"
Output: {"type":"reflect","content":"分析问题的多个角度","continue":true}

Input: "想想有哪些可能的方案"
Output: {"type":"hypothesize","hypotheses":["方案1","方案2"],"selectedHypothesis":"方案1","continue":true}

Input: "需要问用户更多信息"
Output: {"type":"clarify","content":"请问您具体指的是什么？","continue":false}

Input: "直接告诉用户答案就行"
Output: {"type":"answer","content":"","continue":false}

ONLY output JSON. No explanation.''';

    try {
      final cleanBase = workerBase.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$cleanBase/chat/completions');
      
      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $selectedKey',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'model': workerModel,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': 'Parse this: $rawResponse'}
          ],
          'temperature': 0,
          'max_tokens': 150,
        }),
      ).timeout(const Duration(seconds: 10));
      
      if (resp.statusCode == 200) {
        final data = json.decode(utf8.decode(resp.bodyBytes));
        final workerOutput = data['choices'][0]['message']['content'] ?? '';
        
        // Extract JSON from worker output
        final jsonStart = workerOutput.indexOf('{');
        final jsonEnd = workerOutput.lastIndexOf('}');
        if (jsonStart != -1 && jsonEnd > jsonStart) {
          final jsonStr = workerOutput.substring(jsonStart, jsonEnd + 1);
          final parsed = json.decode(jsonStr);
          debugPrint('🤖 Worker parsed intent: $parsed');
          return AgentDecision.fromJson(parsed);
        }
      }
    } catch (e) {
      debugPrint('Worker intent parse error: $e');
    }
    
    return null;
  }

  Future<AgentDecision> _planAgentStep(String userText, List<ReferenceItem> sessionRefs, List<AgentDecision> previousDecisions) async {
    // Use Router config for planning
    final effectiveBase = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerBase : _chatBase;
    final effectiveKey = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerKey : _chatKey;
    final effectiveModel = (_routerKey.isNotEmpty && !_routerBase.contains('your-oneapi-host')) ? _routerModel : _chatModel;

    // 1. Prepare Context Data
    final now = DateTime.now();
    final timeString = "${now.year}年${now.month}月${now.day}日 ${now.hour}:${now.minute} (星期${['','一','二','三','四','五','六','日'][now.weekday]})";
    
    // User Profile (No truncation - critical context)
    String memoryContent = _globalMemoryCache.isNotEmpty ? _globalMemoryCache : "暂无";
    
    // Get historical activity summary (cross-session context)
    String historicalSummary = '';
    try {
      final historicalRefs = await _refManager.getExternalReferences();
      if (historicalRefs.isNotEmpty) {
        final visionHistory = historicalRefs.where((r) => r.sourceType == 'vision').take(5).toList();
        final searchHistory = historicalRefs.where((r) => r.sourceType != 'vision' && r.sourceType != 'generated').take(5).toList();
        
        final summaryBuffer = StringBuffer();
        if (visionHistory.isNotEmpty) {
          summaryBuffer.writeln('📷 最近分析的图片 (${visionHistory.length}):');
          for (var r in visionHistory) {
            final shortSnippet = r.snippet.length > 80 ? '${r.snippet.substring(0, 80)}...' : r.snippet;
            summaryBuffer.writeln('  • $shortSnippet');
          }
        }
        if (searchHistory.isNotEmpty) {
          summaryBuffer.writeln('🔍 最近的搜索/浏览 (${searchHistory.length}):');
          for (var r in searchHistory) {
            summaryBuffer.writeln('  • ${r.title}');
          }
        }
        historicalSummary = summaryBuffer.toString();
      }
    } catch (e) {
      debugPrint('Failed to get historical refs: $e');
    }
    
    // Format References (Observations) with rich metadata AND strict limits
    final refsBuffer = StringBuffer();
    if (sessionRefs.isNotEmpty) {
      // Group by source type for clarity
      final synthesisRefs = sessionRefs.where((r) => r.sourceType == 'synthesis').toList();
      final visionRefs = sessionRefs.where((r) => r.sourceType == 'vision').toList();
      final generatedRefs = sessionRefs.where((r) => r.sourceType == 'generated').toList();
      final knowledgeRefs = sessionRefs.where((r) => r.sourceType == 'knowledge').toList();
      final knowledgeSearchRefs = sessionRefs.where((r) => r.sourceType == 'knowledge_search').toList();
      final thinkingRefs = sessionRefs.where((r) => 
        r.sourceType == 'reflection' || r.sourceType == 'hypothesis' || r.sourceType == 'system' || r.sourceType == 'system_note'
      ).toList();
      
      // URL content (deep read results)
      final urlContentRefs = sessionRefs.where((r) => r.sourceType == 'url_content').toList();
      
      // Filter web refs (exclude knowledge refs and url_content now)
      var webRefs = sessionRefs.where((r) => 
        r.sourceType != 'vision' && r.sourceType != 'generated' && 
        r.sourceType != 'reflection' && r.sourceType != 'hypothesis' && 
        r.sourceType != 'system' && r.sourceType != 'system_note' && r.sourceType != 'synthesis' &&
        r.sourceType != 'knowledge' && r.sourceType != 'knowledge_search' && r.sourceType != 'url_content'
      ).toList();
      
      // LIMIT CONTEXT: Keep only recent/relevant references to prevent context explosion
      if (webRefs.length > 15) {
        // Keep first 3 (often most relevant) and last 12 (most recent)
        final first3 = webRefs.take(3).toList();
        final last12 = webRefs.skip(webRefs.length - 12).toList();
        webRefs = [...first3, ...last12];
        refsBuffer.writeln('⚠️ (Note: Some older search results were hidden to save context space)');
      }
      
      int idx = 1;
      
      // Global Synthesis first (most important overview)
      if (synthesisRefs.isNotEmpty) {
        refsBuffer.writeln('🌐 [全局视角综合分析]');
        refsBuffer.writeln('⚡ 以下是 AI Worker 对所有搜索结果的综合分析，提供全局视角：');
        // Keep only last 2 synthesis results
        for (var r in synthesisRefs.reversed.take(2).toList().reversed) {
          refsBuffer.writeln('${r.snippet}');
          idx++;
        }
        refsBuffer.writeln('');
      }
      
      // Knowledge Base search results (summaries for selection)
      if (knowledgeSearchRefs.isNotEmpty) {
        refsBuffer.writeln('🔍 [知识库搜索结果 - 摘要列表]');
        // Only keep latest search result (previous ones are superseded)
        final latestSearch = knowledgeSearchRefs.last;
        refsBuffer.writeln('  $idx. ${latestSearch.title}');
        refsBuffer.writeln('${latestSearch.snippet}');
        idx++;
        refsBuffer.writeln('');
      }
      
      // Knowledge Base content (actual content from read_knowledge)
      if (knowledgeRefs.isNotEmpty) {
        refsBuffer.writeln('📖 [知识库内容 - 实际文本]');
        for (var r in knowledgeRefs) {
          refsBuffer.writeln('  $idx. ${r.title}');
          refsBuffer.writeln('${r.snippet}');
          idx++;
        }
        refsBuffer.writeln('');
      }
      
      // URL Content (deep read results from read_url action)
      if (urlContentRefs.isNotEmpty) {
        refsBuffer.writeln('📄 [网页深度阅读内容]');
        // Keep last 3 URL reads to prevent context explosion
        for (var r in urlContentRefs.skip(urlContentRefs.length > 3 ? urlContentRefs.length - 3 : 0)) {
          String snippet = r.snippet;
          // Stricter truncation for URL content (it can be very long)
          if (snippet.length > 3000) snippet = '${snippet.substring(0, 3000)}...[截断]';
          refsBuffer.writeln('  $idx. ${r.title}');
          refsBuffer.writeln('     来源: ${r.url}');
          refsBuffer.writeln('     内容: $snippet');
          idx++;
        }
        refsBuffer.writeln('');
      }
      
      // Deep Think observations (recent context)
      if (thinkingRefs.isNotEmpty) {
        refsBuffer.writeln('🧠 [深度思考/系统记录]');
        // Keep last 10 thinking notes
        for (var r in thinkingRefs.skip(thinkingRefs.length > 10 ? thinkingRefs.length - 10 : 0)) {
          refsBuffer.writeln('  $idx. ${r.title}');
          refsBuffer.writeln('     ${r.snippet}');
          idx++;
        }
      }
      
      if (visionRefs.isNotEmpty) {
        refsBuffer.writeln('📷 [图片分析结果]');
        // Keep last 5 vision results
        for (var r in visionRefs.skip(visionRefs.length > 5 ? visionRefs.length - 5 : 0)) {
          String snippet = r.snippet;
          if (snippet.length > 800) snippet = '${snippet.substring(0, 800)}...';
          refsBuffer.writeln('  $idx. ${r.title}: $snippet');
          idx++;
        }
      }
      
      if (generatedRefs.isNotEmpty) {
        refsBuffer.writeln('🎨 [已生成图片]');
        for (var r in generatedRefs) {
          refsBuffer.writeln('  $idx. ${r.title}: ${r.snippet}');
          idx++;
        }
      }
      
      if (webRefs.isNotEmpty) {
        refsBuffer.writeln('🔍 [网络搜索结果 - 显示${webRefs.length}条]');
        for (var r in webRefs) {
          String snippet = r.snippet;
          // Stricter truncation for web results
          if (snippet.length > 500) snippet = '${snippet.substring(0, 500)}...';
          
          // Add reliability indicator
          String reliabilityIcon = '⚪';
          if (r.reliability != null) {
            if (r.reliability! >= 0.8) {
              reliabilityIcon = '🟢'; // High reliability
            } else if (r.reliability! >= 0.6) {
              reliabilityIcon = '🟡'; // Medium reliability
            } else {
              reliabilityIcon = '🔴'; // Low reliability
            }
          }
          
          // Add authority tag
          String authorityTag = '';
          if (r.authorityLevel != null && r.authorityLevel != 'unknown') {
            final authorityLabels = {
              'official': '官方',
              'academic': '学术',
              'professional': '专业',
              'ugc': 'UGC',
            };
            authorityTag = ' [${authorityLabels[r.authorityLevel] ?? r.authorityLevel}]';
          }
          
          refsBuffer.writeln('  $idx. $reliabilityIcon [${r.sourceName}]$authorityTag ${r.title}');
          refsBuffer.writeln('     摘要: $snippet');
          refsBuffer.writeln('     来源: ${r.url}');
          idx++;
        }
      }
    } else {
      refsBuffer.writeln('None yet.');
    }

    // Format Previous Actions with clear status indicators and Deep Think info
    final prevActionsBuffer = StringBuffer();
    
    // META-COGNITION: Detect patterns in action history
    int consecutiveSearches = 0;
    int failedSearches = 0;
    int totalReflections = 0;
    AgentActionType? lastActionType;
    
    if (previousDecisions.isNotEmpty) {
      for (var i = 0; i < previousDecisions.length; i++) {
        final d = previousDecisions[i];
        final contentInfo = d.query ?? d.content ?? 'N/A';
        
        // Track patterns for meta-cognition
        if (d.type == AgentActionType.search) {
          if (lastActionType == AgentActionType.search) {
            consecutiveSearches++;
          } else {
            consecutiveSearches = 1;
          }
          if (d.reason?.contains('failed') == true || d.reason?.contains('No results') == true) {
            failedSearches++;
          }
        }
        if (d.type == AgentActionType.reflect) totalReflections++;
        lastActionType = d.type;
        
        // Extract result status from reason if present
        String status = '⏳ pending';
        String typeIcon = '🔧';
        
        if (d.type == AgentActionType.reflect) {
          typeIcon = '🧠';
          status = '💭 reflected';
        } else if (d.type == AgentActionType.hypothesize) {
          typeIcon = '💡';
          status = '🔀 ${d.hypotheses?.length ?? 0} hypotheses';
        } else if (d.type == AgentActionType.clarify) {
          typeIcon = '❓';
          status = '🗣️ awaiting user input';
        } else if (d.reason?.contains('[RESULT:') == true) {
          if (d.reason!.contains('successfully') || d.reason!.contains('complete')) {
            status = '✅ success';
          } else if (d.reason!.contains('failed') || d.reason!.contains('No results') || d.reason!.contains('error')) {
            status = '❌ failed';
          } else {
            status = '✅ done';
          }
        }
        
        // Add confidence indicator
        String confidenceStr = '';
        if (d.confidence != null) {
          final pct = (d.confidence! * 100).toInt();
          confidenceStr = pct >= 80 ? ' 🟢$pct%' : (pct >= 50 ? ' 🟡$pct%' : ' 🔴$pct%');
        }
        
        prevActionsBuffer.writeln('Step ${i + 1}: $typeIcon ${d.type.name.toUpperCase()} $status$confidenceStr');
        prevActionsBuffer.writeln('  Target: "$contentInfo"');
        if (d.uncertainties != null && d.uncertainties!.isNotEmpty) {
          prevActionsBuffer.writeln('  Uncertainties: ${d.uncertainties!.join(", ")}');
        }
        if (d.selectedHypothesis != null) {
          prevActionsBuffer.writeln('  Selected: ${d.selectedHypothesis}');
        }
        if (d.reason != null && d.reason!.isNotEmpty) {
          prevActionsBuffer.writeln('  Notes: ${d.reason}');
        }
      }
      
      // META-COGNITION ALERTS
      prevActionsBuffer.writeln('\n--- META-COGNITION ALERTS ---');
      if (consecutiveSearches >= 2) {
        prevActionsBuffer.writeln('⚠️ PATTERN: $consecutiveSearches consecutive searches. Consider: REFLECT on current approach or HYPOTHESIZE alternatives.');
      }
      if (failedSearches >= 2) {
        prevActionsBuffer.writeln('🚨 ALERT: $failedSearches failed searches. MUST change strategy: use different keywords, broader/narrower scope, or HYPOTHESIZE new angle.');
      }
      if (previousDecisions.length >= 5 && totalReflections == 0) {
        prevActionsBuffer.writeln('💡 SUGGESTION: 5+ steps without reflection. Consider REFLECT to ensure you\'re on the right track.');
      }
      if (previousDecisions.length >= 3 && !previousDecisions.any((d) => d.type == AgentActionType.hypothesize)) {
        final hasFailure = previousDecisions.any((d) => d.reason?.contains('failed') == true || d.reason?.contains('No results') == true);
        if (hasFailure) {
          prevActionsBuffer.writeln('💡 SUGGESTION: Multiple failures without hypothesizing. Use HYPOTHESIZE to explore alternative approaches.');
        }
      }
    } else {
      prevActionsBuffer.writeln('None yet - this is the first planning step.');
    }

    // Format Chat History（改为“先压缩后限长”，不再直接丢弃旧消息）
    var contextMsgs = List<ChatMessage>.from(_messages);

    // 计算总长，如超限则对旧消息分块摘要，保留最近几条原文
    const int agentCharBudget = 10000;
    final agentTotal = contextMsgs.fold(0, (p, c) => p + c.content.length);
    if (agentTotal > agentCharBudget) {
      contextMsgs = await _compressHistoryForTransport(
        contextMsgs,
        targetChars: agentCharBudget,
        keepTail: 8, // 保留最近交互，旧的转为摘要卡片
      );
      // _compressHistoryForTransport 内部会写 _lastCompressionNote 供 UI 使用
    } else {
      _lastCompressionNote = null;
    }
        
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

    // Tool availability summary so the planner knows what it can actually use
    final prefs = await SharedPreferences.getInstance();
    final searchProviderPref = prefs.getString('search_provider') ?? 'auto';
    final exaKey = prefs.getString('exa_key') ?? '';
    final youKey = prefs.getString('you_key') ?? '';
    final braveKey = prefs.getString('brave_key') ?? '';

    String? resolvedSearchProvider;
    if (searchProviderPref == 'exa' && exaKey.isNotEmpty) {
      resolvedSearchProvider = 'Exa';
    } else if (searchProviderPref == 'you' && youKey.isNotEmpty) {
      resolvedSearchProvider = 'You.com';
    } else if (searchProviderPref == 'brave' && braveKey.isNotEmpty) {
      resolvedSearchProvider = 'Brave';
    } else if (searchProviderPref == 'auto') {
      if (exaKey.isNotEmpty) {
        resolvedSearchProvider = 'Exa';
      } else if (youKey.isNotEmpty) {
        resolvedSearchProvider = 'You.com';
      } else if (braveKey.isNotEmpty) {
        resolvedSearchProvider = 'Brave';
      }
    }

    final searchAvailable = resolvedSearchProvider != null;
    final drawAvailable = !_imgBase.contains('your-oneapi-host') && _imgKey.isNotEmpty;
    final visionAvailable = !_visionBase.contains('your-oneapi-host') && _visionKey.isNotEmpty;

    // Check if we have an active image in this session
    final hasSessionImage = sessionRefs.any((r) => r.sourceType == 'vision');

    // Check if knowledge base has content
    final hasKnowledge = _knowledgeService.hasKnowledge;
    final knowledgeOverview = hasKnowledge ? _knowledgeService.getKnowledgeOverview() : '';

    final toolbelt = '''
### TOOLBELT (what you can call)

**🔧 ACTION TOOLS:**
- search: ${searchAvailable ? "AVAILABLE via $resolvedSearchProvider (web search returns short references)" : "UNAVAILABLE (no search key configured; do NOT pick search)"}
- draw: ${drawAvailable ? "AVAILABLE (image generation; put the full image prompt in content; set continue=true if you want to comment on the result)" : "UNAVAILABLE (image API not configured; do NOT pick draw)"}
- vision: ${visionAvailable ? "AVAILABLE (analyze an image; put custom analysis prompt in content; if user uploaded image, analysis result is in <current_observations>)" : "UNAVAILABLE (vision API not configured)"}
- read_url: ${searchAvailable ? "AVAILABLE - Deep read a specific webpage to get full content. Use when search results snippets are insufficient and you need the complete article/page." : "UNAVAILABLE (no network access)"}
  * content: The full URL to read, e.g., "https://example.com/article"
  * Returns: Title + extracted main content (up to 8000 chars)
  * USE WHEN: Search gave you a relevant URL but snippet is too short to answer the question
  * WORKFLOW: search → review results → read_url on promising link → answer

**📚 KNOWLEDGE BASE TOOLS (3-Step Retrieval Flow):**
${hasKnowledge ? '''
- search_knowledge: AVAILABLE - Search the knowledge base by keywords.
  * STEP 1: Use this FIRST to find relevant chunks.
  * content: Comma-separated keywords, e.g., "authentication, login, token"
  * Returns: Up to 5 chunk summaries per batch, with chunk IDs
  * If more results exist, use same keywords again to get next batch
  
- take_note: AVAILABLE - Save notes to temporary memory.
  * STEP 2 (Optional): After reviewing search results, note which chunks are relevant.
  * content: Your notes, e.g., "Chunk 123_0 covers login flow, 123_3000 covers token refresh"
  * Notes persist for this conversation only.
  * Use this when processing large result sets across multiple batches.

- read_knowledge: AVAILABLE - Read full content of specific chunks.
  * STEP 3: Read the chunks you identified as relevant.
  * content: Comma-separated chunk IDs, e.g., "123_0, 123_3000"
  * Returns: Full text content of the chunks (up to 15000 chars total)

- delete_knowledge: AVAILABLE - Delete content from knowledge base.
  * content: file_id or chunk_id to delete
  * NOTE: Irreversible. Confirm with user first.

**Knowledge Retrieval Workflow Example:**
1. User asks: "How does authentication work?"
2. You: search_knowledge with content="authentication, login, token"
3. System returns: 5 chunk summaries with IDs
4. You: take_note with content="123_0 has login, 123_3000 has token refresh - both relevant"
5. If more batches exist, repeat search_knowledge to see them
6. You: read_knowledge with content="123_0, 123_3000"
7. You: answer based on the content
''' : '''
- search_knowledge: UNAVAILABLE (knowledge base is empty - no files uploaded)
- read_knowledge: UNAVAILABLE (knowledge base is empty)
- delete_knowledge: UNAVAILABLE (knowledge base is empty)
'''}

- save_file: ALWAYS AVAILABLE - Save text or code to a local file. Use when user asks to "save", "download", "create file", or "export". Put filename in "filename" and content in "content".
- system_control: AVAILABLE - Control device global actions.
  * content: "home", "back", "recents", "notifications", "lock", "screenshot"
  * NOTE: Requires Accessibility Service. If action fails, ask user to enable it.

**🧠 THINKING TOOLS:**
- reflect: Pause and self-critique. Use when confused or stuck.
- hypothesize: Generate 2-3 alternative approaches. Use when one path fails.
- clarify: Ask user for missing info. Use when you can't proceed without it.

**📝 OUTPUT:**
- answer: Final response. Use ONLY after tools or for simple greetings.
${hasSessionImage ? """

⚠️ **IMAGE UPLOADED**: Check <current_observations> for vision analysis.
""" : ""}
''';

    // 2. Construct System Prompt with XML Tags for strict separation
    final systemPrompt = '''
You are NOT a chatbot. You are an autonomous AGENT with tools.

## ⚠️ OUTPUT REQUIREMENT: JSON ONLY ⚠️
**YOU MUST OUTPUT ONLY A JSON OBJECT. NO EXPLANATIONS. NO MARKDOWN.**
If you write anything other than JSON, THE SYSTEM CANNOT UNDERSTAND YOU.
Your "hands" and "feet" (tools) are controlled by JSON. Natural language = paralysis.

WRONG OUTPUT (system ignores this):
"我认为需要先搜索一下关于这个话题的最新信息..."

CORRECT OUTPUT (system executes this):
{"type":"search","query":"topic name 2024","reason":"Need latest info","confidence":0.7,"continue":true}

## ⚠️ CRITICAL RULE: TOOL-FIRST PRINCIPLE ⚠️
**BEFORE using "answer", you MUST check if ANY tool can help.**
- If you jump to "answer" without trying tools, you are WRONG.
- The user installed this app FOR THE TOOLS. Direct answers are lazy.

## 🔄 ITERATIVE DECISION LOOP (MOST IMPORTANT!)
You are called MULTIPLE times in a loop. Each time you see:
- <current_observations>: Results from previous tools (search results, vision analysis, etc.)
- <action_history>: What you already tried and their results

**YOUR DECISION PROCESS:**
1. **IF <current_observations> is EMPTY or minimal:**
   → This is your FIRST step. Choose a tool to gather info.
   → Questions about facts/news/data → search
   → User uploaded image → vision (but check if already analyzed in observations)
   → Complex question → reflect

2. **IF <current_observations> has search/vision/knowledge results:**
   → Review the results. Are they SUFFICIENT to answer?
   → If YES: Use "answer" with synthesized info from observations
   → If NO (need more): Use another tool (search with different keywords, read_url for details, etc.)

3. **IF <action_history> shows FAILED attempts:**
   → Don't repeat the same thing! Try a different approach.
   → Multiple failed searches → hypothesize alternative angles
   → Tool returned error → try a different tool

**EXAMPLE MULTI-STEP FLOW:**
Step 1 (observations empty): {"type":"search","query":"AI news December 2024","continue":true}
Step 2 (observations have search results): {"type":"answer","content":"根据搜索结果，今天的AI新闻有...","continue":false}

$toolbelt

## ⚠️ OUTPUT MUST BE PURE JSON ⚠️
Do NOT write natural language. Do NOT explain. Just output a JSON object like:
{"type":"search","query":"xxx","reason":"...","confidence":0.8,"continue":true}

If you write anything other than JSON, the system cannot understand you!

## ✅ EXAMPLE OUTPUTS (copy these patterns!)

**User: "今天有什么新闻"**
→ {"type":"search","query":"今日新闻 2025年12月","reason":"用户问今天新闻，必须搜索","confidence":0.9,"continue":true}

**User: "画一只猫"**
→ {"type":"draw","content":"a cute cat, digital art style, warm colors","reason":"用户要画猫","confidence":0.95,"continue":false}

**User: "帮我保存这段代码"**
→ {"type":"save_file","filename":"code.py","content":"print('hello')","reason":"用户要保存","confidence":1.0,"continue":false}

**User: "回桌面"**
→ {"type":"system_control","content":"home","reason":"控制手机回桌面","confidence":1.0,"continue":false}

**User: "锁屏"**
→ {"type":"system_control","content":"lock","reason":"锁屏","confidence":1.0,"continue":false}

**User: "截个图"**
→ {"type":"system_control","content":"screenshot","reason":"截图","confidence":1.0,"continue":false}

**User: "分析一下这个问题"**
→ {"type":"reflect","content":"这是一个复杂问题，需要从多角度思考...","reason":"复杂问题先反思","confidence":0.6,"continue":true}

**User: "你好"**
→ {"type":"answer","content":"你好呀！有什么可以帮你的？","reason":"简单问候","confidence":1.0,"continue":false}

## ✅ MULTI-STEP DECISION EXAMPLES (CRITICAL!)

**Scenario: User asks "今天比特币价格多少"**

*Step 1 - Observations empty:*
→ {"type":"search","query":"比特币价格 今天 2024年12月","reason":"需要实时数据，先搜索","confidence":0.9,"continue":true}

*Step 2 - Observations now contain search results with price info:*
→ {"type":"answer","content":"根据最新搜索结果，比特币今天的价格是...","reason":"已有搜索结果，可以回答","confidence":0.95,"continue":false}

**Scenario: Search returned no useful results**

*Step 1:*
→ {"type":"search","query":"obscure topic","continue":true}

*Step 2 - Observations show "Search returned 0 results":*
→ {"type":"search","query":"broader topic OR related terms","reason":"上次搜索无结果，换关键词重试","confidence":0.7,"continue":true}

## 🚫 FORBIDDEN (These will FAIL!)
❌ "我认为需要搜索一下..." ← 这不是 JSON！
❌ "让我帮你查找..." ← 这不是 JSON！
❌ "好的，我来画一张..." ← 这不是 JSON！
❌ 任何不以 { 开头的回复！

## 📋 DECISION RULES
**FIRST, check <current_observations>:**
- If observations HAVE useful results → Use "answer" to synthesize them
- If observations are EMPTY/insufficient → Use tools below:

**THEN, match user intent:**
1. "最新/今天/天气/新闻/股价/多少钱" → type: search (gather facts)
2. "画/生成图/设计图" → type: draw  
3. "保存/导出/下载" → type: save_file
4. "回桌面/返回/锁屏/截图/通知" → type: system_control
5. "你好/谢谢/再见" AND no complex question → type: answer
6. Complex question + empty observations → type: search OR reflect
7. Search results exist but not enough detail → type: read_url (deep read)
8. Multiple failed attempts → type: hypothesize (try new angle)

## 🎭 PERSONA
<persona>
${_activePersona.prompt}
</persona>
回答时用这个人格语气，但工具调用不变。

## 📤 JSON SCHEMA
{"type":"search|draw|save_file|system_control|reflect|hypothesize|clarify|answer|search_knowledge|read_knowledge","query":"搜索词(search用)","content":"内容/提示词/回答","filename":"文件名(save_file用)","reason":"为什么选这个","confidence":0.0-1.0,"continue":true/false}
''';

    final userPrompt = '''
<current_time>
$timeString
</current_time>

<user_profile>
$memoryContent
</user_profile>
${historicalSummary.isNotEmpty ? '''
<historical_activity>
$historicalSummary
</historical_activity>
''' : ''}
<knowledge_overview>
$knowledgeOverview
</knowledge_overview>

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
      // Normalize URL - only remove trailing slashes, respect user's path
      String cleanBase = effectiveBase.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$cleanBase/chat/completions');
      
      // Build messages array with REAL multi-turn conversation
      // This is CRITICAL: the model needs to see its previous decisions as assistant messages
      // 
      // Message flow:
      // 1. System prompt (defines agent behavior)
      // 2. Initial user context (user question + observations so far)
      // 3. For each previous decision:
      //    - Assistant message (the decision JSON it made)
      //    - User message (the result from executing that decision)
      // 4. Final prompt asking for next decision
      //
      final List<Map<String, dynamic>> messages = [
        {'role': 'system', 'content': systemPrompt},
      ];
      
      // If this is NOT the first step, we need to show the conversation history
      if (previousDecisions.isNotEmpty) {
        // Add initial context as first user message
        messages.add({'role': 'user', 'content': '''<user_input>
$userText
</user_input>

<initial_context>
This is step ${previousDecisions.length + 1}. Review your previous actions and their results below, then decide your next move.
</initial_context>'''});
        
        // Add each decision-result pair as assistant-user turn
        for (int i = 0; i < previousDecisions.length; i++) {
          final d = previousDecisions[i];
          
          // Reconstruct the decision JSON (what the model outputted)
          final decisionJson = json.encode({
            'type': d.type.name,
            'query': d.query,
            'content': d.content,
            'filename': d.filename,
            'reason': d.reason?.replaceAll(RegExp(r'\[RESULT:[^\]]+\]'), '').trim(), // Remove result from reason
            'confidence': d.confidence,
            'continue': d.continueAfter,
          });
          
          // Add as assistant message
          messages.add({'role': 'assistant', 'content': decisionJson});
          
          // Extract and add result as user message
          String resultInfo = 'Action executed.';
          if (d.reason != null && d.reason!.contains('[RESULT:')) {
            final resultMatch = RegExp(r'\[RESULT:([^\]]+)\]').firstMatch(d.reason!);
            if (resultMatch != null) {
              resultInfo = resultMatch.group(1)!.trim();
            }
          }
          
          // Add result message
          messages.add({
            'role': 'user', 
            'content': '''[STEP ${i + 1} RESULT]
$resultInfo

${i == previousDecisions.length - 1 ? '''
<current_observations>
${refsBuffer.toString()}
</current_observations>

Based on all the information gathered, decide your next action. If you have enough info to answer the user's question, use type "answer".''' : 'Continue to next step.'}'''
          });
        }
      } else {
        // First step - just the initial user prompt with full context
        messages.add({'role': 'user', 'content': userPrompt});
      }
      
      final body = json.encode({
        'model': effectiveModel,
        'messages': messages,
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
        
        // DEBUG: Log the raw response to see what model actually returned
        debugPrint('=== AGENT RAW RESPONSE ===');
        debugPrint(content.length > 500 ? '${content.substring(0, 500)}...' : content);
        debugPrint('=== END RAW RESPONSE ===');
        
        // Strategy 1: Try to extract JSON directly
        final jsonStart = content.indexOf('{');
        final jsonEnd = content.lastIndexOf('}');
        
        if (jsonStart != -1 && jsonEnd != -1 && jsonEnd > jsonStart) {
          final jsonStr = content.substring(jsonStart, jsonEnd + 1);
          try {
            final parsed = json.decode(jsonStr);
            debugPrint('✅ Successfully parsed JSON, type: ${parsed['type']}');
            return AgentDecision.fromJson(parsed);
          } catch (jsonError) {
            debugPrint('❌ JSON parse failed: $jsonError');
            // Continue to Strategy 2
          }
        }
        
        // Strategy 2: Use Worker API to semantically parse natural language into structured intent
        debugPrint('🔄 JSON parse failed, using Worker API for semantic intent extraction...');
        
        try {
          final workerDecision = await _parseIntentWithWorker(content);
          if (workerDecision != null) {
            debugPrint('✅ Worker successfully parsed intent: ${workerDecision.type}');
            return workerDecision;
          }
        } catch (workerError) {
          debugPrint('⚠️ Worker intent parsing failed: $workerError, falling back to regex');
        }
        
        // Strategy 3: Fallback to regex-based extraction (less reliable but works offline)
        debugPrint('🔄 Falling back to regex-based intent extraction...');
        final lowerContent = content.toLowerCase();
        
        // ====== SEARCH INTENT ======
        final searchPatterns = [
          RegExp(r'(搜索|查找|查询|搜一下|查一下|search|look up|find|去.*?找|网上.*?查|了解|获取信息)', caseSensitive: false),
        ];
        for (var pattern in searchPatterns) {
          if (pattern.hasMatch(content)) {
            // Extract any quoted text as query, or use first line
            final quoteMatch = RegExp(r'[""「\'"]([^""」\'"]+)[""」\'"]').firstMatch(content);
            String query = quoteMatch?.group(1) ?? '';
            if (query.isEmpty) {
              query = content.split('\n').first.replaceAll(RegExp(r'[^\w\s\u4e00-\u9fff]'), '').trim();
            }
            if (query.length > 80) query = query.substring(0, 80);
            debugPrint('🔍 Regex inferred SEARCH: "$query"');
            return AgentDecision(
              type: AgentActionType.search,
              query: query.isNotEmpty ? query : '用户问题',
              reason: '[REGEX-FALLBACK] Detected search-like words.',
              continueAfter: true,
            );
          }
        }
        
        // ====== DRAW INTENT ======
        final drawPatterns = [
          RegExp(r'(画|绘制|生成图片|draw|generate image|create image)\s*[：:「"\']?([^」"\'。\n]+)', caseSensitive: false),
          RegExp(r'(应该|需要|可以)\s*(画|绘制|生成)', caseSensitive: false),
        ];
        for (var pattern in drawPatterns) {
          final match = pattern.firstMatch(content);
          if (match != null) {
            String? prompt = match.groupCount >= 2 ? match.group(2)?.trim() : null;
            if (prompt == null || prompt.isEmpty) {
              final quoteMatch = RegExp(r'[""「\'"]([^""」\'"]+)[""」\'"]').firstMatch(content);
              prompt = quoteMatch?.group(1) ?? '用户要求的图片';
            }
            debugPrint('🎨 Inferred DRAW: "$prompt"');
            return AgentDecision(
              type: AgentActionType.draw,
              content: prompt,
              reason: '[AUTO-INFERRED] Detected draw intent.',
              continueAfter: false,
            );
          }
        }
        
        // ====== SAVE FILE INTENT ======
        if (lowerContent.contains('保存') || lowerContent.contains('save') || 
            lowerContent.contains('导出') || lowerContent.contains('export') ||
            lowerContent.contains('下载') || lowerContent.contains('download')) {
          // Try to find filename
          final filenameMatch = RegExp(r'[\w\-]+\.(txt|md|py|js|json|html|css|csv)').firstMatch(content);
          final filename = filenameMatch?.group(0) ?? 'output.txt';
          // Content is everything after "保存" or the whole thing
          debugPrint('💾 Inferred SAVE_FILE: $filename');
          return AgentDecision(
            type: AgentActionType.save_file,
            filename: filename,
            content: content,
            reason: '[AUTO-INFERRED] Detected save intent.',
            continueAfter: false,
          );
        }
        
        // ====== SYSTEM CONTROL INTENT ======
        final controlMap = {
          'home': ['回桌面', '回主页', 'go home', 'home'],
          'back': ['返回', '后退', 'go back', 'back'],
          'lock': ['锁屏', 'lock'],
          'screenshot': ['截图', '截屏', 'screenshot'],
          'notifications': ['通知', '通知栏', 'notifications'],
          'recents': ['最近任务', '多任务', 'recents', 'recent apps'],
        };
        for (var entry in controlMap.entries) {
          for (var keyword in entry.value) {
            if (lowerContent.contains(keyword.toLowerCase())) {
              debugPrint('📱 Inferred SYSTEM_CONTROL: ${entry.key}');
              return AgentDecision(
                type: AgentActionType.system_control,
                content: entry.key,
                reason: '[AUTO-INFERRED] Detected system control intent.',
                continueAfter: false,
              );
            }
          }
        }
        
        // ====== REFLECT INTENT ======
        if (lowerContent.contains('反思') || lowerContent.contains('思考') || 
            lowerContent.contains('分析') || lowerContent.contains('reflect') ||
            lowerContent.contains('think') || lowerContent.contains('consider')) {
          debugPrint('🤔 Inferred REFLECT');
          return AgentDecision(
            type: AgentActionType.reflect,
            content: content.length > 300 ? content.substring(0, 300) : content,
            reason: '[AUTO-INFERRED] Detected reflection/thinking intent.',
            continueAfter: true,
          );
        }
        
        // ====== CLARIFY INTENT ======
        if (content.contains('?') || content.contains('？') ||
            lowerContent.contains('请问') || lowerContent.contains('能否告诉') ||
            lowerContent.contains('需要更多信息') || lowerContent.contains('clarify')) {
          debugPrint('❓ Inferred CLARIFY');
          return AgentDecision(
            type: AgentActionType.clarify,
            content: content,
            reason: '[AUTO-INFERRED] Detected question/clarification intent.',
          );
        }
        
        // ====== KNOWLEDGE BASE INTENT ======
        if (lowerContent.contains('知识库') || lowerContent.contains('上传的文件') ||
            lowerContent.contains('knowledge') || lowerContent.contains('uploaded file')) {
          final keywordMatch = RegExp(r'[""「\'"]([^""」\'"]+)[""」\'"]').firstMatch(content);
          final keywords = keywordMatch?.group(1) ?? content.split('\n').first;
          debugPrint('📚 Inferred SEARCH_KNOWLEDGE: $keywords');
          return AgentDecision(
            type: AgentActionType.search_knowledge,
            content: keywords,
            reason: '[AUTO-INFERRED] Detected knowledge base search intent.',
            continueAfter: true,
          );
        }
        
        // ====== READ URL INTENT ======
        final urlMatch = RegExp(r'https?://[^\s<>"]+').firstMatch(content);
        if (urlMatch != null && (lowerContent.contains('读') || lowerContent.contains('看看') || 
            lowerContent.contains('打开') || lowerContent.contains('访问') ||
            lowerContent.contains('read') || lowerContent.contains('open') || lowerContent.contains('fetch'))) {
          final url = urlMatch.group(0)!;
          debugPrint('🌐 Inferred READ_URL: $url');
          return AgentDecision(
            type: AgentActionType.read_url,
            content: url,
            reason: '[AUTO-INFERRED] Detected URL reading intent.',
            continueAfter: true,
          );
        }
        
        // ====== VISION INTENT ======
        if (lowerContent.contains('看图') || lowerContent.contains('分析图') || 
            lowerContent.contains('图片里') || lowerContent.contains('图中') ||
            lowerContent.contains('analyze image') || lowerContent.contains('看看图')) {
          debugPrint('👁️ Inferred VISION');
          return AgentDecision(
            type: AgentActionType.vision,
            content: content,
            reason: '[AUTO-INFERRED] Detected image analysis intent.',
            continueAfter: true,
          );
        }
        
        // ====== READ KNOWLEDGE INTENT ======
        final chunkIdMatch = RegExp(r'(chunk_\w+|读取\s*[\w_]+)').firstMatch(content);
        if (chunkIdMatch != null || lowerContent.contains('读取知识') || lowerContent.contains('获取块')) {
          final chunkId = chunkIdMatch?.group(0)?.replaceAll('读取', '').trim() ?? '';
          debugPrint('📖 Inferred READ_KNOWLEDGE: $chunkId');
          return AgentDecision(
            type: AgentActionType.read_knowledge,
            content: chunkId.isNotEmpty ? chunkId : content,
            reason: '[AUTO-INFERRED] Detected knowledge reading intent.',
            continueAfter: true,
          );
        }
        
        // ====== DELETE KNOWLEDGE INTENT ======
        if (lowerContent.contains('删除知识') || lowerContent.contains('移除') ||
            lowerContent.contains('delete knowledge') || lowerContent.contains('remove file')) {
          final idMatch = RegExp(r'[\w_-]+\.(txt|md|pdf|doc)').firstMatch(content);
          debugPrint('🗑️ Inferred DELETE_KNOWLEDGE');
          return AgentDecision(
            type: AgentActionType.delete_knowledge,
            content: idMatch?.group(0) ?? content,
            reason: '[AUTO-INFERRED] Detected knowledge deletion intent.',
            continueAfter: false,
          );
        }
        
        // ====== TAKE NOTE INTENT ======
        if (lowerContent.contains('记下') || lowerContent.contains('记录') || 
            lowerContent.contains('note') || lowerContent.contains('记住')) {
          debugPrint('📝 Inferred TAKE_NOTE');
          return AgentDecision(
            type: AgentActionType.take_note,
            content: content,
            reason: '[AUTO-INFERRED] Detected note-taking intent.',
            continueAfter: true,
          );
        }
        
        // ====== HYPOTHESIZE INTENT ======
        if (lowerContent.contains('假设') || lowerContent.contains('可能的方案') || 
            lowerContent.contains('几种方法') || lowerContent.contains('hypothes') ||
            lowerContent.contains('alternatives') || lowerContent.contains('options')) {
          debugPrint('💡 Inferred HYPOTHESIZE');
          return AgentDecision(
            type: AgentActionType.hypothesize,
            content: content,
            hypotheses: ['方案1', '方案2'], // Placeholder
            selectedHypothesis: '方案1',
            reason: '[AUTO-INFERRED] Detected hypothesis generation intent.',
            continueAfter: true,
          );
        }
        
        // ====== MULTI-STEP PLAN DETECTION ======
        // Detect "先...再...然后..." or "1. ... 2. ... 3. ..." patterns
        final multiStepPatterns = [
          RegExp(r'(先|首先|第一步)[：:,，]?\s*(.+?)(再|然后|接着|第二步|之后)', caseSensitive: false),
          RegExp(r'1[\.、]\s*(.+?)\s*2[\.、]', caseSensitive: false),
          RegExp(r'(step\s*1|first)[：:,]?\s*(.+?)(step\s*2|then|next)', caseSensitive: false),
        ];
        
        for (var pattern in multiStepPatterns) {
          final match = pattern.firstMatch(content);
          if (match != null) {
            debugPrint('📋 Detected MULTI-STEP PLAN in response');
            // Extract the FIRST step only, let the loop handle the rest
            String firstStep = match.group(2)?.trim() ?? match.group(1)?.trim() ?? '';
            
            // Now determine what the first step wants to do
            final firstStepLower = firstStep.toLowerCase();
            
            if (firstStepLower.contains('搜索') || firstStepLower.contains('search') || firstStepLower.contains('查找')) {
              final queryMatch = RegExp(r'[""「\'"]([^""」\'"]+)[""」\'"]').firstMatch(firstStep);
              final query = queryMatch?.group(1) ?? firstStep.replaceAll(RegExp(r'(搜索|查找|search)'), '').trim();
              debugPrint('📋 Multi-step: First action is SEARCH: $query');
              return AgentDecision(
                type: AgentActionType.search,
                query: query.isNotEmpty ? query : '用户问题相关信息',
                reason: '[MULTI-STEP PLAN] Step 1: Search. More steps will follow.',
                continueAfter: true, // Important: continue to next step
              );
            }
            
            if (firstStepLower.contains('分析') || firstStepLower.contains('思考') || firstStepLower.contains('理解')) {
              debugPrint('📋 Multi-step: First action is REFLECT');
              return AgentDecision(
                type: AgentActionType.reflect,
                content: '执行多步计划的第一步：$firstStep',
                reason: '[MULTI-STEP PLAN] Step 1: Reflect/Analyze.',
                continueAfter: true,
              );
            }
            
            if (firstStepLower.contains('画') || firstStepLower.contains('生成图')) {
              debugPrint('📋 Multi-step: First action is DRAW');
              return AgentDecision(
                type: AgentActionType.draw,
                content: firstStep,
                reason: '[MULTI-STEP PLAN] Step 1: Draw.',
                continueAfter: true, // Might want to comment on result
              );
            }
            
            // Default: treat first step as reflection to understand the plan
            debugPrint('📋 Multi-step: Converting plan to REFLECT');
            return AgentDecision(
              type: AgentActionType.reflect,
              content: '用户需要多步操作，计划是：$content',
              reason: '[MULTI-STEP PLAN] Converting complex plan to reflection first.',
              continueAfter: true,
            );
          }
        }
        
        // ====== SEQUENTIAL ACTIONS IN LIST FORMAT ======
        // Detect numbered or bulleted lists that might be action sequences
        final listItems = RegExp(r'[\d\-\*•]\s*[\.、]?\s*(.+)').allMatches(content).toList();
        if (listItems.length >= 2) {
          debugPrint('📋 Detected ${listItems.length} list items, treating as plan');
          final firstItem = listItems.first.group(1)?.trim() ?? '';
          final firstItemLower = firstItem.toLowerCase();
          
          // Analyze the first item
          if (firstItemLower.contains('搜索') || firstItemLower.contains('查')) {
            return AgentDecision(
              type: AgentActionType.search,
              query: firstItem.replaceAll(RegExp(r'(搜索|查找|查询|search)'), '').trim(),
              reason: '[LIST PLAN] Executing item 1 of ${listItems.length}.',
              continueAfter: true,
            );
          }
          
          // Default: reflect on the list
          return AgentDecision(
            type: AgentActionType.reflect,
            content: '发现多步计划，共${listItems.length}步：${listItems.map((m) => m.group(1)).join(" → ")}',
            reason: '[LIST PLAN] Reflecting on multi-step plan.',
            continueAfter: true,
          );
        }
        
        // Strategy 3: If nothing matched, treat as answer (but log it)
        debugPrint('⚠️ No intent pattern matched, treating as direct answer');
        return AgentDecision(
          type: AgentActionType.answer,
          content: content,
          reason: '[PASSTHROUGH] No structured intent detected, using raw response as answer.',
        );
        
      } else {
        debugPrint('❌ Agent API returned status ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      debugPrint('❌ Agent planning exception: $e');
    }
    
    // Fallback - but now we know WHY
    debugPrint('⚠️ Falling back to answer due to parsing failure');
    return AgentDecision(type: AgentActionType.answer, reason: "Fallback: Model did not return valid JSON. Check debug logs.");
  }

  // _analyzeIntent removed as it is superseded by _planAgentStep and the Agent Loop.

  Future<void> _send() async {
    // Prevent concurrent sends
    if (_sending) return;
    
    final content = _inputCtrl.text.trim();
    if (content.isEmpty && _selectedImage == null) return;

    String? currentSessionImagePath;
    List<ReferenceItem> sessionRefs = [];
    
    // Knowledge search state: track pagination for batch processing
    int knowledgeSearchBatchIndex = 0;
    String lastKnowledgeSearchKeywords = '';

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

      // Check if we have historical analysis for this image
      final historicalRefs = await _refManager.getReferencesByImageId(currentSessionImagePath);
      if (historicalRefs.isNotEmpty) {
        // Found historical analysis - use it as context
        debugPrint('Found ${historicalRefs.length} historical analysis for image');
        sessionRefs.addAll(historicalRefs);
        // Still do a fresh analysis to capture any new aspects the user might ask about
      }

      // Analyze the image to produce vision references
      try {
        final visionRefs = await analyzeImage(
          imagePath: currentSessionImagePath,
          baseUrl: _visionBase,
          apiKey: _visionKey,
          model: _visionModel,
          // Fallback to Chat API if Vision fails
          fallbackBaseUrl: _chatBase,
          fallbackApiKey: _chatKey,
          fallbackModel: _chatModel,
        );
        if (visionRefs.isNotEmpty) {
          await _refManager.addExternalReferences(visionRefs);
          sessionRefs.addAll(visionRefs);
        } else {
          // Analysis returned empty - add placeholder so Agent knows there's an image
          sessionRefs.add(ReferenceItem(
            title: '用户上传的图片',
            url: currentSessionImagePath,
            snippet: '⚠️ 图片分析未返回内容，可能需要重新分析',
            sourceName: 'VisionAPI',
            imageId: currentSessionImagePath,
            sourceType: 'vision',
          ));
        }
      } catch (e) {
        debugPrint('Vision analyze error: $e');
        // Add error placeholder so Agent knows there's an unanalyzed image
        sessionRefs.add(ReferenceItem(
          title: '用户上传的图片',
          url: currentSessionImagePath,
          snippet: '⚠️ 图片分析失败: $e - 可使用VISION工具重试',
          sourceName: 'VisionAPI',
          imageId: currentSessionImagePath,
          sourceType: 'vision',
        ));
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
    
    // Handle Pending Clarification - restore context from previous clarify request
    if (_pendingClarification != null) {
      debugPrint('Resuming from pending clarification...');
      
      // Restore previous session context
      final prevRefs = _pendingClarification!['sessionRefs'] as List?;
      final prevDecisions = _pendingClarification!['sessionDecisions'] as List?;
      
      if (prevRefs != null) {
        for (var refJson in prevRefs) {
          sessionRefs.add(ReferenceItem.fromJson(refJson as Map<String, dynamic>));
        }
      }
      
      if (prevDecisions != null) {
        for (var decJson in prevDecisions) {
          sessionDecisions.add(AgentDecision.fromJson(decJson as Map<String, dynamic>));
        }
        steps = sessionDecisions.length; // Continue from where we left off
      }
      
      // Add user's clarification response as a special reference
      sessionRefs.add(ReferenceItem(
        title: '✅ 用户补充信息',
        url: 'internal://user-clarification/${DateTime.now().millisecondsSinceEpoch}',
        snippet: '【原始问题】${_pendingClarification!['originalQuery']}\n【用户回复】$content',
        sourceName: 'User',
        sourceType: 'user_input',
      ));
      
      // Clear pending state
      _pendingClarification = null;
    }

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
                // Check if synthesis is enabled
                final prefs = await SharedPreferences.getInstance();
                final enableSynthesis = prefs.getBool('enable_search_synthesis') ?? true;
                
                // Track search count for context
                final searchCount = sessionDecisions.where((d) => d.type == AgentActionType.search).length;
                
                if (enableSynthesis) {
                  // Synthesize search results using Worker API for global perspective
                  setState(() => _loadingStatus = '正在综合分析搜索结果 (搜索#$searchCount)...');
                  try {
                    final synthesisResult = await _refManager.synthesizeSearchResults(
                      refs: uniqueNewRefs,
                      query: decision.query!,
                    );
                    
                    // Add synthesis first if available (so Agent sees global perspective first)
                    final synthesisRef = synthesisResult['synthesis'] as ReferenceItem?;
                    if (synthesisRef != null) {
                      // Enhance synthesis with search context
                      final enhancedSynthesis = ReferenceItem(
                        title: '🌐 搜索#$searchCount 综合分析 (查询: ${decision.query})',
                        url: synthesisRef.url,
                        snippet: '【本次搜索】"${decision.query}" 返回 ${uniqueNewRefs.length} 条结果\n【来源覆盖】${uniqueNewRefs.map((r) => r.sourceName).toSet().join(", ")}\n\n${synthesisRef.snippet}',
                        sourceName: synthesisRef.sourceName,
                        sourceType: 'synthesis',
                        reliability: synthesisRef.reliability,
                        authorityLevel: synthesisRef.authorityLevel,
                        contentDate: synthesisRef.contentDate,
                      );
                      sessionRefs.add(enhancedSynthesis);
                      debugPrint('Added global synthesis perspective for search #$searchCount');
                      
                      // Extract synthesis data for enhanced Agent decision feedback
                      final synthesisData = synthesisResult['synthesisData'] as Map<String, dynamic>?;
                      if (synthesisData != null) {
                        final blindSpots = synthesisData['blind_spots'] as List?;
                        final confidence = synthesisData['confidence_level'] as num?;
                        if (blindSpots != null && blindSpots.isNotEmpty) {
                          debugPrint('Synthesis identified blind spots: $blindSpots');
                          // Add blind spots info to action history for Agent awareness
                          sessionDecisions.last = AgentDecision(
                            type: AgentActionType.search,
                            query: decision.query,
                            reason: '${decision.reason} [RESULT: Found ${uniqueNewRefs.length} results. Synthesis confidence: ${((confidence ?? 0.7) * 100).round()}%. Blind spots: ${blindSpots.join("; ")}]',
                          );
                        }
                      }
                    }
                  } catch (synthError) {
                    debugPrint('Synthesis failed (non-critical): $synthError');
                    // Continue without synthesis - non-critical failure
                  }
                }
                
                // Add individual refs after synthesis
                sessionRefs.addAll(uniqueNewRefs);
                debugPrint('Added ${uniqueNewRefs.length} unique refs (${newRefs.length - uniqueNewRefs.length} duplicates skipped)');
                
                // Record success with result summary (if not already set by synthesis)
                if (sessionDecisions.last.reason?.contains('Blind spots') != true) {
                  final topTitles = uniqueNewRefs.take(3).map((r) => r.title).join(', ');
                  final avgReliability = uniqueNewRefs.fold(0.0, (sum, r) => sum + (r.reliability ?? 0.5)) / uniqueNewRefs.length;
                  sessionDecisions.last = AgentDecision(
                    type: AgentActionType.search,
                    query: decision.query,
                    reason: '${decision.reason} [RESULT: Found ${uniqueNewRefs.length} results (avg reliability: ${(avgReliability * 100).round()}%) - $topTitles]',
                  );
                }
              }
              // Continue loop to re-evaluate with new info
              steps++;
              continue;
            } else {
              // Search returned nothing - let planner decide next action (may rewrite query)
              debugPrint('Search returned no results. Continuing to let planner rewrite query.');
              
              // Explicitly add a system note to observations so the Agent SEES the failure
              sessionRefs.add(ReferenceItem(
                title: 'System Notification: Search Failed',
                url: 'internal://system/search-failed',
                snippet: 'Search for "${decision.query}" returned 0 results. Please try different keywords or a broader topic.',
                sourceName: 'System',
                sourceType: 'system_note',
              ));

              // Mark this in action history so planner knows to try different keywords
              final searchAttempt = sessionDecisions.where((d) => d.type == AgentActionType.search).length;
              sessionDecisions.last = AgentDecision(
                type: AgentActionType.search,
                query: decision.query,
                reason: '${decision.reason} [RESULT: Search #$searchAttempt returned 0 results. Suggestions: 1) Use different keywords 2) Broaden query 3) Try English terms]',
              );
              // Check if we've had too many empty searches
              final emptySearches = sessionDecisions.where((d) => 
                d.type == AgentActionType.search && d.reason?.contains('[RESULT: Search #') == true && d.reason?.contains('returned 0') == true
              ).length;
              if (emptySearches >= 3) {
                debugPrint('3+ empty searches, forcing answer.');
                setState(() => _loadingStatus = '多次搜索无结果，正在生成回答...');
                await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
                break;
              }
              // Otherwise continue loop - planner will see empty result in action history
              steps++;
              continue;
            }
          } catch (searchError) {
            // Search failed - record in action history for planner visibility
            debugPrint('Search failed: $searchError');
            
            // Add error note so Agent can see and try alternative approach
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 搜索失败',
              url: 'internal://error/search/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '搜索 "${decision.query}" 失败: $searchError\n\n可能的解决方案:\n1. 尝试不同的关键词\n2. 使用知识库 (search_knowledge)\n3. 直接回答已知信息',
              sourceName: 'System',
              sourceType: 'system_note',
            ));
            
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.search,
              query: decision.query,
              reason: '${decision.reason} [RESULT: Search error - $searchError. Agent should try alternatives.]',
            );
            
            // Count search failures
            final searchFailures = sessionDecisions.where((d) => 
              d.type == AgentActionType.search && d.reason?.contains('Search error') == true
            ).length;
            
            if (searchFailures >= 3) {
              // Too many failures, force answer
              debugPrint('3+ search failures, forcing answer.');
              setState(() => _loadingStatus = '搜索服务不可用，正在生成回答...');
              await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
              break;
            }
            
            // Continue loop - let Agent try alternative approach
            steps++;
            continue;
          }
        }
        else if (decision.type == AgentActionType.read_url && decision.content != null) {
          // Action: Read URL content - deep read a specific webpage
          final url = decision.content!.trim();
          setState(() => _loadingStatus = '正在阅读网页内容...');
          debugPrint('Agent reading URL: $url');
          
          try {
            final urlRef = await _refManager.fetchUrlContent(url);
            
            // Check if fetch was successful
            if ((urlRef.reliability ?? 0.0) > 0.0) {
              // Success - add to session refs
              sessionRefs.add(urlRef);
              
              final contentLength = urlRef.snippet.length;
              sessionDecisions.last = AgentDecision(
                type: AgentActionType.read_url,
                content: url,
                reason: '${decision.reason} [RESULT: Successfully read $contentLength chars from ${urlRef.sourceName}. Title: "${urlRef.title}"]',
                continueAfter: decision.continueAfter,
              );
              debugPrint('URL read success: $contentLength chars');
            } else {
              // Failed to fetch
              sessionRefs.add(urlRef); // Still add error ref for Agent awareness
              sessionDecisions.last = AgentDecision(
                type: AgentActionType.read_url,
                content: url,
                reason: '${decision.reason} [RESULT: FAILED to read URL. Error: ${urlRef.snippet}]',
              );
            }
            
            if (!decision.continueAfter) {
              // No continue flag, trigger answer
              setState(() => _loadingStatus = '正在生成回答...');
              await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
              break;
            }
            // Continue looping if continue flag is set
            steps++;
            continue;
          } catch (e) {
            debugPrint('read_url error: $e');
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.read_url,
              content: url,
              reason: '${decision.reason} [RESULT: Exception - $e]',
            );
            // Fallback to answer
            setState(() => _loadingStatus = '网页读取失败，正在回答...');
            await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
            break;
          }
        } 
        else if (decision.type == AgentActionType.draw && decision.content != null) {
          // Action: Draw
          setState(() => _loadingStatus = '正在生成图片...');
          final generatedPath = await _performImageGeneration(decision.content!, addUserMessage: false, manageSendingState: false);
          if (generatedPath != null) {
            // Auto-analyze the generated image to get rich semantic info
            setState(() => _loadingStatus = '正在分析生成的图片...');
            String imageDescription = '图片已根据提示词生成: ${decision.content}';
            String analysisStatus = 'pending';
            try {
              final genVisionRefs = await analyzeImage(
                imagePath: generatedPath,
                baseUrl: _visionBase,
                apiKey: _visionKey,
                model: _visionModel,
                userPrompt: '请简洁描述这张AI生成的图片内容，包括主体、风格、色调。一段话即可。',
                fallbackBaseUrl: _chatBase,
                fallbackApiKey: _chatKey,
                fallbackModel: _chatModel,
              );
              if (genVisionRefs.isNotEmpty && !genVisionRefs.first.snippet.contains('⚠️')) {
                imageDescription = '【提示词】${decision.content}\n【实际生成】${genVisionRefs.first.snippet}';
                analysisStatus = 'analyzed';
              } else {
                analysisStatus = 'analysis_failed';
              }
            } catch (e) {
              debugPrint('Auto-analyze generated image failed: $e');
              analysisStatus = 'analysis_error';
            }
            
            // Count generated images for context
            final genCount = sessionRefs.where((r) => r.sourceType == 'generated').length + 1;
            
            // Success - record in action history with rich feedback
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.draw,
              content: decision.content,
              reason: '${decision.reason} [RESULT: Image #$genCount generated successfully. Analysis: $analysisStatus. ${analysisStatus == 'analyzed' ? 'Content verified.' : 'Manual verification recommended.'}]',
              continueAfter: decision.continueAfter,
            );
            
            // Add generated image info with rich description to sessionRefs
            sessionRefs.add(ReferenceItem(
              title: '🎨 生成的图片 #$genCount',
              url: generatedPath,
              snippet: imageDescription,
              sourceName: 'ImageGen',
              imageId: generatedPath,
              sourceType: 'generated',
            ));
            // If continue flag is set, keep looping (e.g., to add a comment about the image)
            if (!decision.continueAfter) {
              break;
            }
            steps++;
            continue;
          } else {
            // Generation returned null (failed)
            debugPrint('Draw returned null');
            final failedPrompt = decision.content ?? '';
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.draw,
              content: decision.content,
              reason: '${decision.reason} [RESULT: Draw FAILED. Possible causes: 1) Invalid prompt 2) Content policy violation 3) API error. Prompt was: "${failedPrompt.length > 50 ? failedPrompt.substring(0, 50) + "..." : failedPrompt}"]',
            );
            // Fallback to answer explaining the failure
            setState(() => _loadingStatus = '生图失败，正在回复...');
            await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
            break;
          }
        }
        else if (decision.type == AgentActionType.read_knowledge && decision.content != null) {
          // Action: Read Knowledge Chunk(s) - supports multiple IDs separated by comma
          setState(() => _loadingStatus = '正在读取知识库...');
          
          // Parse chunk IDs (support comma-separated for batch reading)
          final chunkIds = decision.content!
              .split(RegExp(r'[,\s]+'))
              .map((id) => id.trim())
              .where((id) => id.isNotEmpty)
              .toList();
          
          final successfulReads = <String>[];
          final failedReads = <String>[];
          final combinedContent = StringBuffer();
          int totalChars = 0;
          const maxTotalChars = 15000; // Limit total content to prevent context explosion
          
          for (final chunkId in chunkIds) {
            if (totalChars >= maxTotalChars) {
              failedReads.add('$chunkId (skipped: context limit reached)');
              continue;
            }
            
            final chunkContent = _knowledgeService.getChunkContent(chunkId);
            if (chunkContent != null) {
              successfulReads.add(chunkId);
              
              // Calculate remaining budget
              final remaining = maxTotalChars - totalChars;
              String displayContent = chunkContent;
              if (chunkContent.length > remaining) {
                displayContent = '${chunkContent.substring(0, remaining)}\n[... truncated to fit context limit]';
              }
              
              combinedContent.writeln('═══ Chunk [$chunkId] ═══');
              combinedContent.writeln(displayContent);
              combinedContent.writeln('');
              totalChars += displayContent.length;
              // Don't add individual refs here - we'll add a combined one later
            } else {
              failedReads.add(chunkId);
            }
          }
          
          // Build result message
          String resultMsg;
          if (successfulReads.isNotEmpty) {
            resultMsg = 'Read ${successfulReads.length} chunk(s): ${successfulReads.join(", ")} ($totalChars chars total)';
            if (failedReads.isNotEmpty) {
              resultMsg += '. Failed: ${failedReads.join(", ")}';
            }
          } else {
            // All failed
            final availableIds = _knowledgeService.getAllChunkIds();
            final suggestion = availableIds.isNotEmpty 
                ? 'Available IDs: ${availableIds.take(5).join(", ")}${availableIds.length > 5 ? "..." : ""}'
                : 'Knowledge base is empty.';
            resultMsg = 'All chunks NOT FOUND: ${failedReads.join(", ")}. $suggestion';
            
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 知识库查询失败',
              url: 'internal://knowledge/error',
              snippet: 'Requested chunks not found.\n$suggestion',
              sourceName: 'KnowledgeBase',
              sourceType: 'system_note',
            ));
          }
          
          // Add combined content as a single comprehensive reference
          if (successfulReads.isNotEmpty) {
            sessionRefs.add(ReferenceItem(
              title: '📖 知识库内容 [${successfulReads.join(", ")}]',
              url: 'internal://knowledge/read',
              snippet: combinedContent.toString(),
              sourceName: 'KnowledgeBase',
              sourceType: 'knowledge',
            ));
          }
          
          sessionDecisions.last = AgentDecision(
            type: AgentActionType.read_knowledge,
            content: decision.content,
            reason: '${decision.reason} [RESULT: $resultMsg]',
            continueAfter: true,
          );
          
          // Explicitly continue loop - Agent needs to process the retrieved content
          steps++;
          continue;
        }
        else if (decision.type == AgentActionType.delete_knowledge && decision.content != null) {
          // Action: Delete from Knowledge Base
          setState(() => _loadingStatus = '正在删除知识库内容...');
          final targetId = decision.content!;
          
          // Try to delete as file first, then as chunk
          bool deleted = await _knowledgeService.deleteFile(targetId);
          String deleteType = 'file';
          
          if (!deleted) {
            deleted = await _knowledgeService.deleteChunk(targetId);
            deleteType = 'chunk';
          }
          
          if (deleted) {
            final stats = _knowledgeService.getStats();
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.delete_knowledge,
              content: targetId,
              reason: '${decision.reason} [RESULT: Successfully deleted $deleteType $targetId]',
              continueAfter: true,
            );
            
            sessionRefs.add(ReferenceItem(
              title: '🗑️ 知识库已更新',
              url: 'internal://knowledge/deleted/$targetId',
              snippet: '已删除 $deleteType: $targetId\n当前知识库: ${stats['fileCount']} 个文件, ${stats['chunkCount']} 个知识块',
              sourceName: 'KnowledgeBase',
              sourceType: 'system',
            ));
          } else {
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.delete_knowledge,
              content: targetId,
              reason: '${decision.reason} [RESULT: Failed to delete - ID $targetId not found]',
              continueAfter: true,
            );
            
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 删除失败',
              url: 'internal://knowledge/delete-error',
              snippet: 'ID "$targetId" 在知识库中未找到。',
              sourceName: 'KnowledgeBase',
              sourceType: 'system_note',
            ));
          }
          steps++;
          continue;
        }
        else if (decision.type == AgentActionType.search_knowledge && decision.content != null) {
          // Action: Search Knowledge Base
          setState(() => _loadingStatus = '正在搜索知识库...');
          final keywords = decision.content!;
          
          // Check if this is a continuation of previous search (for pagination)
          if (keywords == lastKnowledgeSearchKeywords) {
            knowledgeSearchBatchIndex++; // Next batch
          } else {
            knowledgeSearchBatchIndex = 0; // New search, reset
            lastKnowledgeSearchKeywords = keywords;
          }
          
          final searchResult = _knowledgeService.searchChunks(
            keywords: keywords,
            batchIndex: knowledgeSearchBatchIndex,
            batchSize: 5,
          );
          
          final results = searchResult['results'] as List<Map<String, dynamic>>;
          final totalMatches = searchResult['totalMatches'] as int;
          final hasMore = searchResult['hasMore'] as bool;
          final remainingCount = searchResult['remainingCount'] ?? 0;
          
          // Build result message for Agent
          final resultBuffer = StringBuffer();
          if (results.isEmpty) {
            resultBuffer.writeln('No matches found for keywords: "$keywords"');
            if (searchResult['message'] != null) {
              resultBuffer.writeln(searchResult['message']);
            }
          } else {
            resultBuffer.writeln('📚 Search Results (Batch ${knowledgeSearchBatchIndex + 1}, showing ${results.length} of $totalMatches matches):');
            resultBuffer.writeln('Keywords: $keywords\n');
            
            for (var result in results) {
              resultBuffer.writeln('━━━━━━━━━━━━━━━━━━━━');
              resultBuffer.writeln('📄 File: ${result['filename']}');
              resultBuffer.writeln('🔖 Chunk ID: ${result['id']} (Chunk #${result['chunkIndex']})');
              resultBuffer.writeln('🎯 Match Score: ${result['score']} keyword(s)');
              resultBuffer.writeln('📝 Summary: ${result['summary']}');
            }
            
            if (hasMore) {
              resultBuffer.writeln('\n⏳ More results available: $remainingCount remaining');
              resultBuffer.writeln('💡 Use search_knowledge with same keywords to see next batch.');
              resultBuffer.writeln('💡 Or use take_note to record findings, then read_knowledge to get content.');
            } else {
              resultBuffer.writeln('\n✅ All $totalMatches results shown.');
            }
          }
          
          // Add to session refs for context (use different sourceType for search vs read)
          sessionRefs.add(ReferenceItem(
            title: '🔍 知识库搜索: "$keywords"',
            url: 'internal://knowledge/search',
            snippet: resultBuffer.toString(),
            sourceName: 'KnowledgeBase',
            sourceType: 'knowledge_search',
          ));
          
          sessionDecisions.last = AgentDecision(
            type: AgentActionType.search_knowledge,
            content: keywords,
            reason: '${decision.reason} [RESULT: Found $totalMatches matches, showing batch ${knowledgeSearchBatchIndex + 1}]',
            continueAfter: true,
          );
          
          steps++;
          continue;
        }
        else if (decision.type == AgentActionType.take_note && decision.content != null) {
          // Action: Take Note (Agent's temporary memory)
          setState(() => _loadingStatus = '正在记录笔记...');
          final noteContent = decision.content!;
          
          // Count existing notes
          final noteCount = sessionRefs.where((r) => r.sourceName == 'AgentNotes').length + 1;
          
          // Also add as reference so Agent sees it in context
          sessionRefs.add(ReferenceItem(
            title: '📝 Agent 笔记 #$noteCount',
            url: 'internal://notes/session/$noteCount',
            snippet: noteContent,
            sourceName: 'AgentNotes',
            sourceType: 'system_note',
          ));
          
          sessionDecisions.last = AgentDecision(
            type: AgentActionType.take_note,
            content: noteContent,
            reason: '${decision.reason} [NOTE #$noteCount SAVED]',
            continueAfter: true,
          );
          
          steps++;
          continue;
        }
        else if (decision.type == AgentActionType.save_file && decision.filename != null && decision.content != null) {
          // Action: Save File
          setState(() => _loadingStatus = '正在保存文件: ${decision.filename}...');
          debugPrint('Agent saving file: ${decision.filename}');
          
          final savedPath = await FileSaver.saveTextFile(decision.filename!, decision.content!);
          
          if (savedPath != null) {
             // Success
             sessionDecisions.last = AgentDecision(
                type: AgentActionType.save_file,
                filename: decision.filename,
                content: decision.content,
                reason: '${decision.reason} [RESULT: File saved successfully to $savedPath]',
                continueAfter: decision.continueAfter,
             );
             
             sessionRefs.add(ReferenceItem(
                title: '💾 文件已保存',
                url: 'file://$savedPath',
                snippet: '文件 ${decision.filename} 已保存。\n路径: $savedPath',
                sourceName: 'FileSaver',
                sourceType: 'system',
             ));
          } else {
             // Failed or Cancelled
             sessionDecisions.last = AgentDecision(
                type: AgentActionType.save_file,
                filename: decision.filename,
                content: decision.content,
                reason: '${decision.reason} [RESULT: File save cancelled or failed]',
                continueAfter: decision.continueAfter,
             );
          }
          
          if (!decision.continueAfter) {
             break;
          }
          steps++;
          continue;
        }
        else if (decision.type == AgentActionType.system_control && decision.content != null) {
          // Action: System Control
          final action = decision.content!.toLowerCase();
          setState(() => _loadingStatus = '正在执行系统操作: $action...');
          
          // Check service status first
          final isEnabled = await SystemControl.isServiceEnabled();
          if (!isEnabled) {
             // Service not enabled - ask user
             sessionDecisions.last = AgentDecision(
                type: AgentActionType.system_control,
                content: decision.content,
                reason: '${decision.reason} [RESULT: FAILED - Accessibility Service not enabled]',
             );
             
             // Add system note
             sessionRefs.add(ReferenceItem(
                title: '⚠️ 需要权限',
                url: 'internal://system/permission-required',
                snippet: '执行 "$action" 失败。需要开启无障碍服务权限。\n请引导用户去设置开启。',
                sourceName: 'SystemControl',
                sourceType: 'system',
             ));
             
             // Prompt user to open settings
             setState(() {
               _messages.add(ChatMessage('assistant', '执行该操作需要开启【无障碍服务】权限。\n请点击下方按钮开启，然后重试。'));
               _messages.add(ChatMessage('system', '点击开启设置', isMemory: true)); // Placeholder for UI action if we had one, but text is fine
             });
             
             // Open settings automatically
             await SystemControl.openAccessibilitySettings();
             break;
          }
          
          bool success = false;
          String actionResult = '';
          switch (action) {
            case 'home': success = await SystemControl.goHome(); actionResult = 'home'; break;
            case 'back': success = await SystemControl.goBack(); actionResult = 'back'; break;
            case 'recents': success = await SystemControl.showRecents(); actionResult = 'recents'; break;
            case 'notifications': success = await SystemControl.showNotifications(); actionResult = 'notifications'; break;
            case 'lock': success = await SystemControl.lockScreen(); actionResult = 'lock'; break;
            case 'screenshot': success = await SystemControl.takeScreenshot(); actionResult = 'screenshot'; break;
            default: 
              success = false;
              actionResult = 'UNKNOWN';
              debugPrint('Unknown system action: $action');
              // Record available actions for agent context
              sessionRefs.add(ReferenceItem(
                title: '❓ 未知的系统操作',
                url: 'internal://system/unknown-action',
                snippet: '操作 "$action" 不支持。\n支持的操作有: home, back, recents, notifications, lock, screenshot\n请使用支持的操作或改用其他工具。',
                sourceName: 'SystemControl',
                sourceType: 'system_note',
              ));
          }
          
          sessionDecisions.last = AgentDecision(
            type: AgentActionType.system_control,
            content: decision.content,
            reason: '${decision.reason} [RESULT: ${success ? "SUCCESS" : "FAILED"}]',
            continueAfter: decision.continueAfter,
          );
          
          if (success) {
             sessionRefs.add(ReferenceItem(
                title: '📱 系统操作执行',
                url: 'internal://system/action-performed',
                snippet: '已执行操作: $action',
                sourceName: 'SystemControl',
                sourceType: 'system',
             ));
          }
          
          if (!decision.continueAfter) break;
          steps++;
          continue;
        }
        else if (decision.type == AgentActionType.vision && currentSessionImagePath != null) {
          // Action: Additional Vision Analysis (with custom prompt)
          // Count existing vision analyses for context
          final existingVisionCount = sessionRefs.where((r) => r.sourceType == 'vision').length;
          setState(() => _loadingStatus = '正在深度分析图片 (第${existingVisionCount + 1}次分析)...');
          try {
            final customPrompt = decision.content ?? '请详细分析这张图片的内容。';
            final visionRefs = await analyzeImage(
              imagePath: currentSessionImagePath,
              baseUrl: _visionBase,
              apiKey: _visionKey,
              model: _visionModel,
              userPrompt: customPrompt,
              // Fallback to Chat API if Vision fails
              fallbackBaseUrl: _chatBase,
              fallbackApiKey: _chatKey,
              fallbackModel: _chatModel,
            );
            if (visionRefs.isNotEmpty) {
              // Mark as additional analysis with context
              for (var ref in visionRefs) {
                // Enhance snippet with analysis context
                final enhancedSnippet = '【分析视角】$customPrompt\n【分析结果】${ref.snippet}';
                sessionRefs.add(ReferenceItem(
                  title: '📷 深度分析 #${existingVisionCount + 1}: ${ref.title}',
                  url: ref.url,
                  snippet: enhancedSnippet,
                  sourceName: ref.sourceName,
                  imageId: ref.imageId,
                  sourceType: 'vision',
                ));
              }
              debugPrint('Added ${visionRefs.length} vision refs (analysis #${existingVisionCount + 1})');
              
              // Extract key insights for action history
              final firstResult = visionRefs.first.snippet;
              final summaryPreview = firstResult.length > 100 ? '${firstResult.substring(0, 100)}...' : firstResult;
              
              // Record success in action history with rich feedback
              sessionDecisions.last = AgentDecision(
                type: AgentActionType.vision,
                content: customPrompt,
                reason: '${decision.reason} [RESULT: Vision #${existingVisionCount + 1} complete. Key insight: $summaryPreview]',
              );
            } else {
              // Vision returned empty - record for planner
              sessionDecisions.last = AgentDecision(
                type: AgentActionType.vision,
                content: customPrompt,
                reason: '${decision.reason} [RESULT: Vision returned no insights - try different analysis angle]',
              );
            }
            // Continue loop to process the new vision info
          } catch (visionError) {
            debugPrint('Vision analysis failed: $visionError');
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.vision,
              content: decision.content,
              reason: '${decision.reason} [RESULT: Vision failed - $visionError. Consider: 1) Different prompt 2) Fallback to describe without analysis]',
            );
            // Continue loop - Agent will decide next action based on failure
          }
          steps++;
          continue; // Always continue after vision to let Agent decide next action
        }
        else if (decision.type == AgentActionType.reflect) {
          // Action: Self-Reflection (Deep Think)
          final reflectionSummary = decision.content ?? '自我审视当前方法';
          // Show the actual thought process in UI
          setState(() => _loadingStatus = '🤔 反思: ${reflectionSummary.length > 15 ? reflectionSummary.substring(0, 15) + "..." : reflectionSummary}');
          debugPrint('Agent reflecting: ${decision.content}');
          
          // Artificial delay to let user see the thinking state
          await Future.delayed(const Duration(milliseconds: 1200));
          
          // Record reflection in action history with insights
          sessionDecisions.last = AgentDecision(
            type: AgentActionType.reflect,
            content: reflectionSummary,
            reason: '${decision.reason} [REFLECTION: $reflectionSummary]',
            confidence: decision.confidence,
            uncertainties: decision.uncertainties,
          );
          
          // Add reflection as a special observation for next iteration
          sessionRefs.add(ReferenceItem(
            title: '🧠 深度反思',
            url: 'internal://reflection/${DateTime.now().millisecondsSinceEpoch}',
            snippet: '【反思结论】$reflectionSummary\n【置信度】${((decision.confidence ?? 0.5) * 100).toInt()}%\n【待解决不确定性】${decision.uncertainties?.join(", ") ?? "无"}',
            sourceName: 'DeepThink',
            sourceType: 'reflection',
          ));
          
          // Reflect always continues to next action
          // (Agent will decide what to do based on reflection)
          steps++;
          continue; // Continue loop to let Agent decide next action
        }
        else if (decision.type == AgentActionType.hypothesize) {
          // Action: Multi-Hypothesis Generation (Deep Think)
          final hypothesesList = decision.hypotheses ?? ['默认方案'];
          final selected = decision.selectedHypothesis ?? hypothesesList.first;
          
          setState(() => _loadingStatus = '💡 假设: ${selected.length > 15 ? selected.substring(0, 15) + "..." : selected}');
          debugPrint('Agent hypothesizing: ${decision.hypotheses}');
          
          // Artificial delay
          await Future.delayed(const Duration(milliseconds: 1200));
          
          // Record hypotheses in action history
          sessionDecisions.last = AgentDecision(
            type: AgentActionType.hypothesize,
            content: selected,
            reason: '${decision.reason} [HYPOTHESES: ${hypothesesList.length} generated, selected: $selected]',
            confidence: decision.confidence,
            hypotheses: hypothesesList,
            selectedHypothesis: selected,
          );
          
          // Add hypothesis analysis as observation
          final hypothesesBuffer = StringBuffer();
          hypothesesBuffer.writeln('【候选方案】');
          for (var i = 0; i < hypothesesList.length; i++) {
            final isSelected = hypothesesList[i] == selected || selected.contains(hypothesesList[i]);
            hypothesesBuffer.writeln('  ${i + 1}. ${isSelected ? "✅" : "○"} ${hypothesesList[i]}');
          }
          hypothesesBuffer.writeln('【选定方案】$selected');
          
          sessionRefs.add(ReferenceItem(
            title: '💡 假设分析',
            url: 'internal://hypothesis/${DateTime.now().millisecondsSinceEpoch}',
            snippet: hypothesesBuffer.toString(),
            sourceName: 'DeepThink',
            sourceType: 'hypothesis',
          ));
          
          // Hypothesize always continues to execute the selected hypothesis
          steps++;
          continue; // Continue loop to let Agent execute the selected hypothesis
        }
        else if (decision.type == AgentActionType.clarify) {
          // Action: Request Clarification from User
          setState(() => _loadingStatus = '❓ 需要您提供更多信息...');
          debugPrint('Agent requesting clarification: ${decision.content}');
          
          final clarificationRequest = decision.content ?? '请提供更多信息';
          final missingInfoList = decision.infoSufficiency?.missingInfo ?? [];
          
          // Record clarification request in action history
          sessionDecisions.last = AgentDecision(
            type: AgentActionType.clarify,
            content: clarificationRequest,
            reason: '${decision.reason} [CLARIFY: Awaiting user input]',
            confidence: decision.confidence,
            infoSufficiency: decision.infoSufficiency,
          );
          
          // Build a user-friendly clarification message
          final clarifyBuffer = StringBuffer();
          clarifyBuffer.writeln('🤔 **需要更多信息**\n');
          clarifyBuffer.writeln(clarificationRequest);
          
          if (missingInfoList.isNotEmpty) {
            clarifyBuffer.writeln('\n\n📋 **具体需要了解：**');
            for (var i = 0; i < missingInfoList.length; i++) {
              clarifyBuffer.writeln('${i + 1}. ${missingInfoList[i]}');
            }
          }
          
          if (decision.infoSufficiency != null && !decision.infoSufficiency!.isSufficient) {
            clarifyBuffer.writeln('\n📊 当前信息充分度: 不足');
          }
          
          clarifyBuffer.writeln('\n\n*请回复补充信息后，我将继续为您分析。*');
          
          // Add clarification to session refs for context
          sessionRefs.add(ReferenceItem(
            title: '❓ 信息请求',
            url: 'internal://clarify/${DateTime.now().millisecondsSinceEpoch}',
            snippet: '【缺失信息】${missingInfoList.join("; ")}\n【状态】等待用户回复',
            sourceName: 'DeepThink',
            sourceType: 'system',
          ));
          
          // Create clarification message and end the Agent loop
          final clarifyMessage = ChatMessage(
            'assistant',
            clarifyBuffer.toString(),
          );
          
          setState(() {
            _messages.add(clarifyMessage);
            _sending = false;
            _loadingStatus = '';
          });
          
          // Save the clarification state so next user message continues the flow
          _pendingClarification = {
            'sessionRefs': sessionRefs.map((r) => r.toJson()).toList(),
            'sessionDecisions': sessionDecisions.map((d) => d.toJson()).toList(),
            'originalQuery': content,
          };
          
          await _saveChatHistory();
          return; // Exit Agent loop, wait for user input
        }
        else if (decision.type == AgentActionType.answer || 
                 (decision.type == AgentActionType.vision && currentSessionImagePath == null)) {
          // Action: Answer (or vision without image = fallback to answer)
          
          // 🔴 CRITICAL FIX: Prevent premature answering on first step
          // If this is the FIRST step and Agent chose "answer" without using any tools,
          // force it to think about whether tools could help.
          // Exceptions: simple greetings, follow-up questions, or explicit user requests
          final isSimpleGreeting = content.length < 10 && 
            (content.contains('你好') || content.contains('hi') || content.contains('hello') ||
             content.contains('谢谢') || content.contains('再见') || content.contains('好的'));
          final hasToolsAlreadyUsed = sessionDecisions.any((d) => 
            d.type != AgentActionType.answer && 
            d.type != AgentActionType.reflect && 
            d.type != AgentActionType.hypothesize);
          
          if (steps == 0 && !isSimpleGreeting && !hasToolsAlreadyUsed && sessionRefs.isEmpty) {
            // First step, no tools used, no refs gathered - force reflection
            debugPrint('⚠️ GUARD: Agent tried to answer on step 0 without using tools. Forcing tool consideration.');
            setState(() => _loadingStatus = '🤔 正在分析是否需要搜索或其他工具...');
            
            // Inject a strong hint to use tools
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 系统提示：请优先使用工具',
              url: 'internal://system/tool-first-reminder',
              snippet: '您尝试在第一步直接回答，但系统要求：\n1. 如果问题涉及最新信息、事实核查、专业知识 → 使用 search\n2. 如果用户要画图 → 使用 draw\n3. 如果问题复杂 → 使用 reflect\n请重新考虑是否有合适的工具可用。只有简单问候或确认才应直接回答。',
              sourceName: 'System',
              sourceType: 'system_note',
            ));
            
            // Record this attempt in decision history
            sessionDecisions.add(AgentDecision(
              type: AgentActionType.reflect,
              content: '系统阻止了直接回答，要求先考虑工具使用',
              reason: '[SYSTEM GUARD] Prevented premature answer. User asked: "$content". Must reconsider tools.',
            ));
            
            steps++;
            continue;
          }
          
          // Deep Think: Check confidence before answering
          if (decision.needsMoreWork && steps < maxSteps - 2) {
            // Confidence too low - force a reflection before answering
            debugPrint('Confidence ${decision.confidence} too low, forcing reflection');
            setState(() => _loadingStatus = '🤔 置信度不足，正在深入思考...');
            
            // Add a note that we're forcing more thought
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 置信度检查',
              url: 'internal://confidence-check/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '系统检测到回答置信度为 ${((decision.confidence ?? 0.5) * 100).toInt()}%，低于阈值70%。\n已触发深度思考模式，将重新评估策略。\n【不确定性】${decision.uncertainties?.join(", ") ?? "未明确"}',
              sourceName: 'DeepThink',
              sourceType: 'system',
            ));
            
            // Continue loop to let Agent reconsider
            steps++;
            continue;
          }
          
          setState(() => _loadingStatus = '正在撰写回复...');
          await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
          break; // Answer is a terminal action
        }
        else {
          // ⚠️ CRITICAL: Handle missing parameters for tool calls
          // If we reach here, it means a tool was called but with missing parameters
          // Instead of silently falling back to answer, we should:
          // 1. Log the issue
          // 2. Add a system note so Agent can see what went wrong
          // 3. Continue the loop so Agent can retry
          
          final toolName = decision.type.name;
          String missingParams = '';
          
          // Check what's missing for each tool type
          switch (decision.type) {
            case AgentActionType.search:
              if (decision.query == null) missingParams = 'query';
              break;
            case AgentActionType.read_url:
            case AgentActionType.draw:
            case AgentActionType.vision:
            case AgentActionType.search_knowledge:
            case AgentActionType.read_knowledge:
            case AgentActionType.delete_knowledge:
            case AgentActionType.take_note:
            case AgentActionType.system_control:
              if (decision.content == null) missingParams = 'content';
              break;
            case AgentActionType.save_file:
              final missing = <String>[];
              if (decision.filename == null) missing.add('filename');
              if (decision.content == null) missing.add('content');
              missingParams = missing.join(', ');
              break;
            case AgentActionType.hypothesize:
              if (decision.hypotheses == null) missingParams = 'hypotheses';
              break;
            default:
              missingParams = 'unknown';
          }
          
          debugPrint('⚠️ Tool $toolName called with missing params: $missingParams');
          
          // Add error note to session so Agent can see and fix
          sessionRefs.add(ReferenceItem(
            title: '⚠️ 工具调用失败: $toolName',
            url: 'internal://error/missing-params/${DateTime.now().millisecondsSinceEpoch}',
            snippet: '工具 "$toolName" 缺少必要参数: $missingParams\n请重新调用该工具并提供完整参数。\n\n正确格式示例:\n${_getToolExample(decision.type)}',
            sourceName: 'System',
            sourceType: 'system_note',
          ));
          
          // Record in decision history
          sessionDecisions.last = AgentDecision(
            type: decision.type,
            content: decision.content,
            reason: '${decision.reason ?? ""} [ERROR: Missing params: $missingParams]',
          );
          
          // Continue loop to let Agent retry with correct parameters
          if (steps < maxSteps - 1) {
            steps++;
            continue;
          }
          
          // If too many retries, fallback to answer
          setState(() => _loadingStatus = '工具调用失败，正在撰写回复...');
          await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
          break;
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

  /// Get example JSON for a tool type (used in error messages)
  String _getToolExample(AgentActionType type) {
    switch (type) {
      case AgentActionType.search:
        return '{"type":"search","query":"搜索关键词","continue":true}';
      case AgentActionType.read_url:
        return '{"type":"read_url","content":"https://example.com","continue":true}';
      case AgentActionType.draw:
        return '{"type":"draw","content":"a beautiful sunset","continue":false}';
      case AgentActionType.vision:
        return '{"type":"vision","content":"请分析这张图片","continue":true}';
      case AgentActionType.save_file:
        return '{"type":"save_file","filename":"report.md","content":"文件内容...","continue":false}';
      case AgentActionType.system_control:
        return '{"type":"system_control","content":"home","continue":false}';
      case AgentActionType.search_knowledge:
        return '{"type":"search_knowledge","content":"关键词","continue":true}';
      case AgentActionType.read_knowledge:
        return '{"type":"read_knowledge","content":"chunk_id","continue":true}';
      case AgentActionType.delete_knowledge:
        return '{"type":"delete_knowledge","content":"file_id","continue":false}';
      case AgentActionType.take_note:
        return '{"type":"take_note","content":"重要笔记内容","continue":true}';
      case AgentActionType.reflect:
        return '{"type":"reflect","content":"思考内容","continue":true}';
      case AgentActionType.hypothesize:
        return '{"type":"hypothesize","hypotheses":["方案1","方案2"],"selectedHypothesis":"方案1","continue":true}';
      case AgentActionType.clarify:
        return '{"type":"clarify","content":"请问您具体指...?","continue":false}';
      case AgentActionType.answer:
        return '{"type":"answer","content":"回答内容","continue":false}';
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

  void _showSuccessSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(msg, style: const TextStyle(fontWeight: FontWeight.w500))),
          ],
        ),
        backgroundColor: Colors.green[600],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
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
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppColors.backgroundGradient,
        ),
        child: Column(
          children: [
            // 华丽渐变 AppBar
            _buildGlassAppBar(context, totalChars, isMemoryFull),
            
            // 记忆状态栏 - 玻璃效果
            if (totalChars > 0)
              _buildMemoryStatusBar(totalChars, isMemoryFull),
            
            // 消息列表 - 带动画效果
            Expanded(
              child: _messages.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        // 为最新的消息添加弹入动画
                        final isRecent = index >= _messages.length - 2;
                        if (isRecent) {
                          return TweenAnimationBuilder<double>(
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeOutBack,
                            tween: Tween(begin: 0.0, end: 1.0),
                            builder: (context, value, child) {
                              return Transform.translate(
                                offset: Offset(0, 20 * (1 - value)),
                                child: Opacity(
                                  opacity: value.clamp(0.0, 1.0),
                                  child: Transform.scale(
                                    scale: 0.95 + 0.05 * value,
                                    child: child,
                                  ),
                                ),
                              );
                            },
                            child: _buildMessageItem(_messages[index]),
                          );
                        }
                        return _buildMessageItem(_messages[index]);
                      },
                    ),
            ),
          
            // 华丽输入区域
            _buildFancyInputArea(context),
          ],
        ),
      ),
    );
  }

  // 记忆状态栏
  Widget _buildMemoryStatusBar(int totalChars, bool isMemoryFull) {
    final progress = (totalChars / 20000).clamp(0.0, 1.0);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: isMemoryFull 
                ? Colors.red.withOpacity(0.15)
                : AppColors.shadowLight,
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(
          color: isMemoryFull 
              ? Colors.red.withOpacity(0.3)
              : Colors.white.withOpacity(0.5),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              gradient: isMemoryFull 
                  ? const LinearGradient(colors: [Color(0xFFFF6B6B), Color(0xFFEE5A5A)])
                  : AppColors.primaryGradient,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              isMemoryFull ? Icons.warning_amber_rounded : Icons.psychology_rounded, 
              size: 16, 
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMemoryFull ? '记忆即将满载' : '记忆容量',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isMemoryFull ? Colors.red[700] : Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 4),
                Stack(
                  children: [
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[200],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: progress,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          gradient: isMemoryFull 
                              ? const LinearGradient(colors: [Color(0xFFFF6B6B), Color(0xFFEE5A5A)])
                              : AppColors.primaryGradient,
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: [
                            BoxShadow(
                              color: (isMemoryFull ? Colors.red : AppColors.primaryStart).withOpacity(0.4),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$totalChars',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: isMemoryFull ? Colors.red : AppColors.primaryStart,
            ),
          ),
          if (totalChars > 500)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _sending ? null : _performAdaptiveCompression,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: isMemoryFull 
                          ? const LinearGradient(colors: [Color(0xFFFF6B6B), Color(0xFFEE5A5A)])
                          : AppColors.primaryGradient,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: (isMemoryFull ? Colors.red : AppColors.primaryStart).withOpacity(0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Text(
                      '压缩',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // 空状态 - 带动画效果
  Widget _buildEmptyState() {
    return Center(
      child: AnimatedBuilder(
        animation: _floatAnimation,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _floatAnimation.value),
            child: child,
          );
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
              scale: _pulseAnimation,
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primaryStart.withOpacity(0.4),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 48,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 32),
            ShaderMask(
              shaderCallback: (bounds) => AppColors.primaryGradient.createShader(bounds),
              child: const Text(
                '开始新的对话',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.8),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.shadowLight,
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _activePersona.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 华丽输入区域 - 玻璃质感
  Widget _buildFancyInputArea(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withOpacity(0.85),
                Colors.white.withOpacity(0.95),
              ],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(
                color: Colors.white.withOpacity(0.8),
                width: 1.5,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadowMedium,
                blurRadius: 20,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 加载状态 - 使用跳动动画
                if (_sending)
                  _loadingStatus.contains('搜索知识库') || _loadingStatus.contains('读取知识库')
                      ? _buildScanningIndicator(_loadingStatus.isEmpty ? '正在思考...' : _loadingStatus)
                      : Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          child: Row(
                            children: [
                              _buildBouncingDots(),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  _loadingStatus.isEmpty ? '正在思考...' : _loadingStatus,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppColors.primaryStart,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                // 已选图片预览
                if (_selectedImage != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.primaryStart.withOpacity(0.1),
                          AppColors.primaryEnd.withOpacity(0.05),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.primaryStart.withOpacity(0.2)),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(File(_selectedImage!.path), width: 50, height: 50, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('已选择图片', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              Text('点击发送进行识图', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close_rounded, size: 20, color: Colors.grey[400]),
                          onPressed: () => setState(() => _selectedImage = null),
                        ),
                      ],
                    ),
                  ),
                // 输入行
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // 图片按钮
                      _buildInputActionButton(
                        icon: Icons.add_photo_alternate_rounded,
                        onPressed: _sending ? null : _pickImage,
                        tooltip: '发送图片',
                      ),
                      // 文件按钮
                      _buildInputActionButton(
                        icon: Icons.attach_file_rounded,
                        onPressed: _sending ? null : _pickAndIngestFile,
                        tooltip: '上传文件',
                      ),
                      // 生图按钮
                      _buildInputActionButton(
                        icon: Icons.auto_fix_high_rounded,
                        onPressed: _sending ? null : _manualGenerateImage,
                        tooltip: 'AI 生图',
                      ),
                      const SizedBox(width: 8),
                      // 输入框
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.grey[200]!),
                          ),
                          child: TextField(
                            controller: _inputCtrl,
                            maxLines: 5,
                            minLines: 1,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sending ? null : _send(),
                            style: const TextStyle(fontSize: 15),
                            decoration: InputDecoration(
                              hintText: '输入消息...',
                              hintStyle: TextStyle(color: Colors.grey[400]),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 发送按钮 - 带脉冲动画
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          final canSend = !_sending && (_inputCtrl.text.trim().isNotEmpty || _selectedImage != null);
                          return Transform.scale(
                            scale: canSend ? 1.0 + (_pulseAnimation.value - 1.0) * 0.3 : 1.0,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: _sending ? null : AppColors.primaryGradient,
                                color: _sending ? Colors.grey[300] : null,
                                shape: BoxShape.circle,
                                boxShadow: _sending ? null : [
                                  BoxShadow(
                                    color: AppColors.primaryStart.withOpacity(0.3 + _pulseAnimation.value * 0.2),
                                    blurRadius: 12 + _pulseAnimation.value * 8,
                                    offset: const Offset(0, 4),
                                    spreadRadius: _pulseAnimation.value * 2,
                                  ),
                                ],
                              ),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: _sending ? null : _send,
                                  borderRadius: BorderRadius.circular(24),
                                  child: Container(
                                    width: 48,
                                    height: 48,
                                    alignment: Alignment.center,
                                    child: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 200),
                                      child: _sending
                                          ? SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor: AlwaysStoppedAnimation(Colors.grey[500]),
                                              ),
                                            )
                                          : Icon(
                                              Icons.arrow_upward_rounded,
                                              key: const ValueKey('send'),
                                              color: Colors.white,
                                              size: 24,
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputActionButton({
    required IconData icon,
    required VoidCallback? onPressed,
    required String tooltip,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          child: Icon(
            icon,
            color: onPressed != null ? Colors.grey[600] : Colors.grey[400],
            size: 24,
          ),
        ),
      ),
    );
  }

  // 华丽玻璃效果 AppBar
  Widget _buildGlassAppBar(BuildContext context, int totalChars, bool isMemoryFull) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.primaryStart.withOpacity(0.9),
                AppColors.primaryEnd.withOpacity(0.85),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withOpacity(0.2),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryStart.withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              // 主 AppBar 区域
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    // 标题区域
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'One-API 助手',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: Colors.greenAccent,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.greenAccent.withOpacity(0.5),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _chatModel,
                                style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.8),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // 操作按钮
                _buildAppBarButton(
                  icon: Icons.delete_outline_rounded,
                  onPressed: () {
                    setState(() {
                      _messages.clear();
                      _saveChatHistory();
                      _refManager.clearExternalReferences();
                    });
                  },
                  tooltip: '清空对话',
                ),
                _buildPersonaSwitcher(context),
                _buildAppBarButton(
                  icon: Icons.settings_outlined,
                  onPressed: _openSettings,
                  tooltip: '设置',
                ),
              ],
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }

  Widget _buildAppBarButton({
    required IconData icon,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Widget _buildPersonaSwitcher(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '切换人格',
      offset: const Offset(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: p.id == _currentPersonaId 
                        ? AppColors.primaryGradient 
                        : null,
                    color: p.id != _currentPersonaId ? Colors.grey[200] : null,
                    image: p.avatarPath != null && File(p.avatarPath!).existsSync()
                        ? DecorationImage(image: FileImage(File(p.avatarPath!)), fit: BoxFit.cover)
                        : null,
                  ),
                  child: p.avatarPath == null 
                      ? Icon(Icons.person, size: 16, color: p.id == _currentPersonaId ? Colors.white : Colors.grey) 
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(p.name, style: TextStyle(
                    fontWeight: p.id == _currentPersonaId ? FontWeight.bold : FontWeight.normal,
                    color: p.id == _currentPersonaId ? AppColors.primaryStart : null,
                  )),
                ),
                if (p.id == _currentPersonaId)
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check, size: 12, color: Colors.white),
                  ),
              ],
            ),
          )),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'manage',
            child: Row(
              children: [
                Icon(Icons.settings_accessibility, size: 20, color: Colors.grey),
                SizedBox(width: 12),
                Text('管理人格...'),
              ],
            ),
          ),
        ];
      },
      child: Container(
        padding: const EdgeInsets.all(10),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.people_outline, color: Colors.white, size: 20),
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.grey[200]!.withOpacity(0.8),
                Colors.grey[100]!.withOpacity(0.8),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.grey[300]!.withOpacity(0.5)),
          ),
          child: Text(
            m.content,
            style: TextStyle(fontSize: 11, color: Colors.grey[600], fontWeight: FontWeight.w500),
          ),
        ),
      );
    }

    // 压缩消息 UI - 更华丽
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
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.grey[100]!, Colors.grey[50]!],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey[300]!),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.compress, size: 12, color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '已压缩 (${(m.compressionRatio! * 100).toInt()}%)',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey[700]),
                        ),
                      ),
                      Text(
                        '${m.content.length}字',
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Stack(
                    children: [
                      Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: m.compressionRatio!,
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            gradient: AppColors.primaryGradient,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
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

    // 普通消息 - 华丽气泡
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            _buildAvatar(isUser: false),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isUser)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            gradient: AppColors.primaryGradient,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _activePersona.name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    gradient: isUser 
                        ? AppColors.userMessageGradient 
                        : LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white,
                              Colors.grey[50]!,
                            ],
                          ),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(20),
                      topRight: const Radius.circular(20),
                      bottomLeft: Radius.circular(isUser ? 20 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 20),
                    ),
                    border: isUser ? null : Border.all(
                      color: Colors.white.withOpacity(0.8),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isUser 
                            ? AppColors.primaryStart.withOpacity(0.3)
                            : Colors.black.withOpacity(0.08),
                        blurRadius: isUser ? 12 : 10,
                        offset: const Offset(0, 4),
                      ),
                      if (!isUser) BoxShadow(
                        color: Colors.white.withOpacity(0.8),
                        blurRadius: 1,
                        offset: const Offset(0, -1),
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
                          inlineSyntaxes: [
                            BlockMathSyntax(),
                            InlineMathSyntax(),
                          ],
                          builders: {
                            'inline_math': MathBuilder(isBlock: false),
                            'block_math': MathBuilder(isBlock: true),
                          },
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
        width: 40, height: 40,
        decoration: BoxDecoration(
          gradient: AppColors.primaryGradient,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryStart.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(Icons.person_rounded, size: 22, color: Colors.white),
      );
    } else {
      final avatarPath = _activePersona.avatarPath;
      final hasAvatar = avatarPath != null && File(avatarPath).existsSync();
      
      return Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          gradient: hasAvatar ? null : AppColors.primaryGradient,
          color: hasAvatar ? Colors.white : null,
          shape: BoxShape.circle,
          image: hasAvatar 
              ? DecorationImage(image: FileImage(File(avatarPath)), fit: BoxFit.cover)
              : null,
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryStart.withOpacity(0.25),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: !hasAvatar 
            ? Center(
                child: Text(
                  _activePersona.name.isNotEmpty ? _activePersona.name[0] : '?',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.white,
                  ),
                ),
              )
            : null,
      );
    }
  }
  
  /// 跳动的加载点点指示器
  Widget _buildBouncingDots() {
    return AnimatedBuilder(
      animation: _loadingDotsController,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            // 每个点的动画延迟
            final delay = index * 0.2;
            final value = (_loadingDotsController.value + delay) % 1.0;
            // 使用正弦曲线创建弹跳效果
            final bounce = math.sin(value * math.pi);
            
            return Transform.translate(
              offset: Offset(0, -bounce * 6),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primaryStart.withOpacity(0.6 + bounce * 0.4),
                      AppColors.primaryEnd.withOpacity(0.6 + bounce * 0.4),
                    ],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primaryStart.withOpacity(bounce * 0.5),
                      blurRadius: 4 + bounce * 4,
                      spreadRadius: bounce * 2,
                    ),
                  ],
                ),
              ),
            );
          }),
        );
      },
    );
  }
  
  /// 知识库搜索时的扫描动画组件
  Widget _buildScanningIndicator(String text) {
    return AnimatedBuilder(
      animation: _loadingDotsController,
      builder: (context, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              // 扫描动画图标
              Stack(
                alignment: Alignment.center,
                children: [
                  // 外圈旋转
                  Transform.rotate(
                    angle: _loadingDotsController.value * 2 * math.pi,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.primaryStart.withOpacity(0.3),
                          width: 2,
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: AppColors.primaryStart,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 中心点
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ShaderMask(
                  shaderCallback: (bounds) {
                    final progress = _loadingDotsController.value;
                    return LinearGradient(
                      colors: [
                        AppColors.primaryStart,
                        AppColors.primaryEnd,
                        AppColors.primaryStart,
                      ],
                      stops: [
                        (progress - 0.3).clamp(0.0, 1.0),
                        progress,
                        (progress + 0.3).clamp(0.0, 1.0),
                      ],
                    ).createShader(bounds);
                  },
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
