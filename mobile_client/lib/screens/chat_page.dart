import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf_render/pdf_render.dart' as pdf_render;
import 'package:image/image.dart' as img;
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
import '../services/document_parser.dart';
import '../services/task_queue.dart';
import '../utils/constants.dart';
import '../models/task.dart';
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
  late AnimationController _backgroundController; // 背景动效
  late AnimationController _sendButtonController; // 发送按钮特效
  late Animation<double> _pulseAnimation;
  late Animation<double> _floatAnimation;
  late Animation<double> _backgroundAnimation;
  final ScrollController _scrollCtrl = ScrollController();
  
  // 推理链/Plan 显示
  bool _showReasoningPanel = false;
  String _currentReasoning = ''; // 当前推理过程
  List<String> _reasoningSteps = []; // 推理步骤列表
  final ImagePicker _picker = ImagePicker();
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final ReferenceManager _refManager = ReferenceManager();
  final KnowledgeService _knowledgeService = KnowledgeService();
  final TaskQueueService _taskQueue = TaskQueueService();
  
  bool _sending = false;
  String _loadingStatus = ''; // To show detailed agent status
  final List<ChatMessage> _messages = [];
  XFile? _selectedImage;
  
  // Deep Think: Pending clarification state
  Map<String, dynamic>? _pendingClarification;
  
  // PLANNER: Current execution plan (if any)
  AgentPlan? _currentPlan;
  int _currentPlanStep = 0; // Which step of the plan we're on
  
  // 初始化状态标志
  bool _isInitialized = false;
  Timer? _taskPollTimer;
  bool _taskPollInProgress = false;

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
  // OCR (Dedicated, do not reuse Vision/Chat)
  String _ocrBase = '';
  String _ocrKey = '';
  String _ocrModel = 'gpt-4o-mini';
  // Deep reasoning mode
  bool _deepReasoningMode = false;
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
    _initializeApp(); // 统一的异步初始化入口
    _startTaskPolling();
  }
  
  /// 统一异步初始化，确保正确的加载顺序
  Future<void> _initializeApp() async {
    // 1. 先加载人格配置（决定 _currentPersonaId）
    await _loadPersonas();
    
    // 2. 初始化知识库服务
    await _knowledgeService.init();
    await _taskQueue.loadFromStorage();
    
    // 3. 设置当前人格的知识库
    await _knowledgeService.setPersona(_currentPersonaId);
    
    // 4. 最后加载聊天历史（依赖 _currentPersonaId）
    await _loadChatHistory();
    
    // 5. 标记初始化完成
    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
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
    
    // 背景动效控制器 - 渐变流动
    _backgroundController = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    )..repeat();
    _backgroundAnimation = Tween<double>(begin: 0, end: 2 * math.pi).animate(
      CurvedAnimation(parent: _backgroundController, curve: Curves.linear),
    );
    
    // 发送按钮特效控制器
    _sendButtonController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
  }
  
  @override
  void dispose() {
    _pulseController.dispose();
    _floatController.dispose();
    _loadingDotsController.dispose();
    _backgroundController.dispose();
    _sendButtonController.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _taskPollTimer?.cancel();
    super.dispose();
  }
  
  /// 带重试机制的 HTTP POST 请求
  /// [maxRetries] 最大重试次数，[baseDelay] 初始退避延迟（毫秒）
  Future<http.Response> _postWithRetry(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
    Duration timeout = const Duration(minutes: 2),
    int maxRetries = 2,
    int baseDelay = 1000,
  }) async {
    int attempt = 0;
    http.Response? lastResponse;
    Object? lastError;
    
    while (attempt <= maxRetries) {
      try {
        final response = await http.post(
          uri,
          headers: headers,
          body: body,
        ).timeout(timeout);
        
        // 成功或非临时性错误直接返回
        if (response.statusCode == 200 || 
            response.statusCode == 400 || 
            response.statusCode == 401 ||
            response.statusCode == 403) {
          return response;
        }
        
        // 5xx 或 429 可重试
        if (response.statusCode >= 500 || response.statusCode == 429) {
          lastResponse = response;
          debugPrint('🔄 API 请求失败 (${response.statusCode})，尝试 ${attempt + 1}/$maxRetries...');
        } else {
          return response; // 其他错误不重试
        }
      } catch (e) {
        lastError = e;
        debugPrint('🔄 API 请求异常: $e，尝试 ${attempt + 1}/$maxRetries...');
      }
      
      attempt++;
      if (attempt <= maxRetries) {
        // 指数退避
        await Future.delayed(Duration(milliseconds: baseDelay * attempt));
      }
    }
    
    // 返回最后一次响应或抛出最后一个错误
    if (lastResponse != null) return lastResponse;
    throw lastError ?? Exception('API 请求失败');
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
    _ocrBase = prefs.getString('ocr_base') ?? '';
    _ocrKey = prefs.getString('ocr_key') ?? '';
    _ocrModel = prefs.getString('ocr_model') ?? 'gpt-4o-mini';
    _deepReasoningMode = prefs.getBool('deep_reasoning_mode') ?? false;

      _routerBase = prefs.getString('router_base') ?? 'https://your-oneapi-host/v1';
      _routerKey = prefs.getString('router_key') ?? '';
      _routerModel = prefs.getString('router_model') ?? 'gpt-3.5-turbo';

      _profileBase = prefs.getString('profile_base') ?? 'https://your-oneapi-host/v1';
      _profileKey = prefs.getString('profile_key') ?? '';
      _profileModel = prefs.getString('profile_model') ?? 'gpt-3.5-turbo';
    });
  }

  /// 添加推理步骤并更新 UI
  void _addReasoningStep(String step) {
    if (!mounted) return;
    debugPrint('[推理] $step');
    setState(() {
      if (!_reasoningSteps.contains(step)) {
        _reasoningSteps.add(step);
      }
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
          'txt', 'md', 'markdown', 'rst', 'log', 'csv', 'tsv', 'pdf', 'docx',
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
        
        // Check size (raised limit to 50MB to allow larger documents)
        final size = await file.length();
        if (size > 50 * 1024 * 1024) {
          _showError('文件过大 (限制50MB)');
          return;
        }

        setState(() {
          _sending = true;
          _showReasoningPanel = true;  // 显示推理面板
          _reasoningSteps = [];
          _loadingStatus = '正在读取并索引文件...';
        });
        
        _addReasoningStep('📂 开始处理文件: $filename (${(size / 1024).toStringAsFixed(1)} KB)');

        try {
          final ext = filename.split('.').last.toLowerCase();
          String content;
          _addReasoningStep('🔍 尝试解析 $ext 格式...');
          try {
            content = await DocumentParser.readText(file, extension: ext);
            if (content.trim().isNotEmpty) {
              _addReasoningStep('✅ 文本解析成功: ${content.length} 字符');
            }
          } catch (e) {
            _addReasoningStep('❌ 解析失败: $e');
            _showError('无法解析${ext.toUpperCase()} 文件: $e');
            return;
          }
          
          if (content.trim().isEmpty) {
            // Fallback: OCR for scanned PDFs via OpenAI-compatible vision API
            if (ext == 'pdf') {
              _addReasoningStep('⚠️ 文本解析为空，尝试 OCR...');
              setState(() => _loadingStatus = '文本提取为空，正在尝试 OCR...');
              try {
                final ocrText = await _runPdfOcr(file);
                if (ocrText != null && ocrText.trim().isNotEmpty) {
                  content = ocrText;
                } else {
                  _addReasoningStep('❌ OCR 未提取到文本');
                  _showError('文件内容为空，OCR 也未能提取文本');
                  return;
                }
              } catch (e) {
                _showError('文件内容为空，OCR 失败: $e');
                return;
              }
            } else if (ext == 'docx') {
              _addReasoningStep('❌ Word 文档解析为空');
              _showError('Word 文档解析为空。可能是扫描版文档，请转为图片后上传使用 OCR。');
              return;
            } else {
              _addReasoningStep('❌ 文件内容为空');
              _showError('文件内容为空，或未能提取文本');
              return;
            }
          }
          
          _addReasoningStep('📝 正在索引到知识库...');
          await _knowledgeService.ingestFile(
            filename: filename,
            content: content,
            summarizer: (chunk) => _generateKnowledgeSummary(chunk, filename), // File-type aware summary
          );

          // Get stats for user feedback
          final stats = _knowledgeService.getStats();
          final fileInfo = _knowledgeService.files.where((f) => f.filename == filename).lastOrNull;
          final chunkCount = fileInfo?.chunks.length ?? 0;
          
          _addReasoningStep('✅ 索引完成: $chunkCount 个知识块');
          
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
          _addReasoningStep('❌ 处理失败: $e');
          _showError('处理文件失败: $e');
        } finally {
          setState(() {
            _sending = false;
            _loadingStatus = '';
            // 保持推理面板显示几秒后自动隐藏
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted && !_sending) {
                setState(() {
                  _showReasoningPanel = false;
                });
              }
            });
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
      if (currentTotal > 50000 && _messages.length > 15) { // 用户API支持60K tokens
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

  /// OCR a file (PDF or image) using an OpenAI-compatible vision/chat endpoint
  /// For PDF: Attempts direct PDF OCR first, falls back to page-by-page image conversion
  /// For images: Sends directly with appropriate mime type
  Future<String?> _runPdfOcr(File file, {String? prompt}) async {
    // Use dedicated OCR config only
    if (_ocrBase.isEmpty || _ocrKey.isEmpty || _ocrBase.contains('your-oneapi-host')) {
      debugPrint('OCR skipped: no OCR API configured');
      _addReasoningStep('OCR 跳过: 未配置 OCR API');
      return null;
    }
    final base = _ocrBase;
    final key = _ocrKey;
    final model = _ocrModel;
    
    final ext = file.path.toLowerCase().split('.').last;
    _addReasoningStep('开始 OCR 处理: ${file.path.split('/').last} (类型: $ext, 模型: $model)');

    final cleanBase = base.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$cleanBase/chat/completions');
    final bytes = await file.readAsBytes();
    
    final userPrompt = prompt ??
        '<image>\n<|grounding|>Convert the document to markdown. Output in Chinese if the content is Chinese.';

    // Helper function to send OCR request
    Future<http.Response> sendOcrRequest(String dataUrl) async {
      final body = json.encode({
        'model': model,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': dataUrl}
              },
              {'type': 'text', 'text': userPrompt}
            ]
          }
        ],
        'stream': false,
      });

      return await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json',
        },
        body: body,
      ).timeout(const Duration(minutes: 3));
    }
    
    // Helper function to extract text from OCR response
    String? extractOcrText(http.Response resp) {
      if (resp.statusCode == 200) {
        final data = json.decode(utf8.decode(resp.bodyBytes));
        return data['choices']?[0]?['message']?['content']?.toString();
      }
      return null;
    }

    // For images, send directly
    if (ext != 'pdf') {
      String mimeType;
      switch (ext) {
        case 'png': mimeType = 'image/png'; break;
        case 'jpg':
        case 'jpeg': mimeType = 'image/jpeg'; break;
        case 'gif': mimeType = 'image/gif'; break;
        case 'webp': mimeType = 'image/webp'; break;
        default: mimeType = 'image/png';
      }
      
      final b64 = base64Encode(bytes);
      _addReasoningStep('图片大小: ${(bytes.length / 1024).toStringAsFixed(1)} KB');
      
      final resp = await sendOcrRequest('data:$mimeType;base64,$b64');
      final text = extractOcrText(resp);
      if (text != null && text.isNotEmpty) {
        _addReasoningStep('OCR 成功，提取到 ${text.length} 字符');
        return text;
      }
      
      if (resp.statusCode != 200) {
        throw Exception('OCR API 错误 ${resp.statusCode}: ${resp.body}');
      }
      return null;
    }
    
    // For PDF: Try direct first, then page-by-page
    _addReasoningStep('PDF 文件: ${(bytes.length / 1024).toStringAsFixed(1)} KB');
    
    // Attempt 1: Try direct PDF OCR
    _addReasoningStep('尝试直接 PDF OCR...');
    final b64 = base64Encode(bytes);
    var resp = await sendOcrRequest('data:application/pdf;base64,$b64');
    
    if (resp.statusCode == 200) {
      final text = extractOcrText(resp);
      if (text != null && text.isNotEmpty) {
        _addReasoningStep('直接 PDF OCR 成功，提取到 ${text.length} 字符');
        return text;
      }
    }
    
    // Attempt 2: Convert PDF pages to images and OCR each
    if (resp.statusCode == 400 || resp.statusCode == 422 || extractOcrText(resp)?.isEmpty == true) {
      _addReasoningStep('直接 PDF OCR 失败，尝试逐页转图片...');
      
      try {
        // Open PDF document
        final pdfDoc = await pdf_render.PdfDocument.openData(bytes);
        final pageCount = pdfDoc.pageCount;
        _addReasoningStep('PDF 共 $pageCount 页，开始逐页 OCR...');
        
        final allText = StringBuffer();
        int successPages = 0;
        
        // Process each page (limit to first 10 pages for performance)
        final maxPages = pageCount > 10 ? 10 : pageCount;
        
        for (int i = 1; i <= maxPages; i++) {
          try {
            _addReasoningStep('处理第 $i/$pageCount 页...');
            
            final page = await pdfDoc.getPage(i);
            // Render at 150 DPI for good quality/size balance
            const scale = 150.0 / 72.0;
            final width = (page.width * scale).toInt();
            final height = (page.height * scale).toInt();
            
            final pageImage = await page.render(
              width: width,
              height: height,
              fullWidth: width.toDouble(),
              fullHeight: height.toDouble(),
            );
            
            // Convert RGBA pixels to PNG
            final image = img.Image.fromBytes(
              width: pageImage.width,
              height: pageImage.height,
              bytes: pageImage.pixels.buffer,
              numChannels: 4,
            );
            final pngBytes = img.encodePng(image);
            final pageB64 = base64Encode(pngBytes);
            
            // OCR this page
            final pageResp = await sendOcrRequest('data:image/png;base64,$pageB64');
            final pageText = extractOcrText(pageResp);
            
            if (pageText != null && pageText.isNotEmpty) {
              successPages++;
              if (pageCount > 1) {
                allText.writeln('\n--- 第 $i 页 ---\n');
              }
              allText.writeln(pageText);
            }
          } catch (pageError) {
            debugPrint('Page $i OCR error: $pageError');
            _addReasoningStep('第 $i 页处理失败: $pageError');
          }
        }
        
        pdfDoc.dispose();
        
        if (maxPages < pageCount) {
          allText.writeln('\n--- (仅处理了前 $maxPages 页，共 $pageCount 页) ---');
          _addReasoningStep('⚠️ PDF 较长，仅处理了前 $maxPages 页');
        }
        
        if (successPages > 0) {
          final result = allText.toString().trim();
          _addReasoningStep('✅ PDF OCR 完成: $successPages 页成功，提取 ${result.length} 字符');
          return result;
        } else {
          throw Exception('PDF 所有页面 OCR 都失败了');
        }
        
      } catch (pdfError) {
        _addReasoningStep('PDF 拆分 OCR 失败: $pdfError');
        throw Exception('PDF OCR 失败: $pdfError\n\n建议: 尝试截图 PDF 页面后上传。');
      }
    }
    
    // Other errors
    String errorDetail = resp.body;
    try {
      final errorJson = json.decode(resp.body);
      if (errorJson['error'] != null) {
        errorDetail = errorJson['error']['message'] ?? errorJson['error'].toString();
      }
    } catch (_) {}
    
    _addReasoningStep('OCR 失败: HTTP ${resp.statusCode} - $errorDetail');
    throw Exception('OCR API 错误 ${resp.statusCode}: $errorDetail');
  }

  /// OCR for images (png/jpg/etc) - simplified version for Agent tool
  /// Supports both local files and data URLs
  Future<String?> _runImageOcr(File imageFile, {String? prompt}) async {
    if (_ocrBase.isEmpty || _ocrKey.isEmpty || _ocrBase.contains('your-oneapi-host')) {
      throw Exception('OCR API 未配置');
    }
    
    final bytes = await imageFile.readAsBytes();
    final ext = imageFile.path.toLowerCase().split('.').last;
    
    // Determine MIME type
    String mimeType;
    switch (ext) {
      case 'png': mimeType = 'image/png'; break;
      case 'jpg':
      case 'jpeg': mimeType = 'image/jpeg'; break;
      case 'gif': mimeType = 'image/gif'; break;
      case 'webp': mimeType = 'image/webp'; break;
      case 'bmp': mimeType = 'image/bmp'; break;
      default: mimeType = 'image/png'; // Default to PNG
    }
    
    final b64 = base64Encode(bytes);
    final dataUrl = 'data:$mimeType;base64,$b64';
    
    final cleanBase = _ocrBase.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$cleanBase/chat/completions');
    
    final userPrompt = prompt ?? '<|grounding|>OCR this image. Extract all visible text.';
    
    final body = json.encode({
      'model': _ocrModel,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {
                'url': dataUrl,
              }
            },
            {'type': 'text', 'text': userPrompt}
          ]
        }
      ],
      'stream': false,
    });

    final resp = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_ocrKey',
        'Content-Type': 'application/json',
      },
      body: body,
    ).timeout(const Duration(minutes: 2));

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final content = data['choices']?[0]?['message']?['content']?.toString() ?? '';
      return content.isNotEmpty ? content : null;
    }

    // Parse error for better message
    String errorDetail = resp.body;
    try {
      final errorJson = json.decode(resp.body);
      if (errorJson['error'] != null) {
        errorDetail = errorJson['error']['message'] ?? errorJson['error'].toString();
      }
    } catch (_) {}
    
    throw Exception('OCR API 错误 ${resp.statusCode}: $errorDetail');
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
    else if (['md', 'markdown', 'rst', 'txt', 'log', 'pdf', 'docx'].contains(ext)) {
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
      
      // 使用带重试的请求（Worker 请求可以快速失败）
      final resp = await _postWithRetry(
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
          'max_tokens': 500,
        }),
        timeout: const Duration(seconds: 15),
        maxRetries: 1, // Worker 快速重试一次即可
      );
      
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
      
      // 💡 System feedback (observations for Agent to consider)
      final feedbackRefs = sessionRefs.where((r) => r.sourceType == 'feedback').toList();
      
      // URL content (deep read results)
      final urlContentRefs = sessionRefs.where((r) => r.sourceType == 'url_content').toList();
      
      // Filter web refs (exclude all special types)
      var webRefs = sessionRefs.where((r) => 
        r.sourceType != 'vision' && r.sourceType != 'generated' && 
        r.sourceType != 'reflection' && r.sourceType != 'hypothesis' && 
        r.sourceType != 'system' && r.sourceType != 'system_note' && r.sourceType != 'synthesis' &&
        r.sourceType != 'knowledge' && r.sourceType != 'knowledge_search' && r.sourceType != 'url_content' &&
        r.sourceType != 'feedback' && r.sourceType != 'ocr' && r.sourceType != 'pending_image'
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
      
      // 💡 SYSTEM FEEDBACK FIRST (most important for decision-making)
      // This ensures Agent sees the feedback prominently before other data
      if (feedbackRefs.isNotEmpty) {
        refsBuffer.writeln('═══════════════════════════════════════════════════════════════');
        refsBuffer.writeln('💡 [系统观察反馈 - 请阅读后自行决策]');
        refsBuffer.writeln('═══════════════════════════════════════════════════════════════');
        for (var r in feedbackRefs) {
          refsBuffer.writeln(r.snippet);
          refsBuffer.writeln('');
        }
      }
      
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
          // 用户API支持60K tokens，允许更完整的内容
          if (snippet.length > 8000) snippet = '${snippet.substring(0, 8000)}...[截断]';
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
          if (snippet.length > 2000) snippet = '${snippet.substring(0, 2000)}...';
          refsBuffer.writeln('  $idx. ${r.title}: $snippet');
          idx++;
        }
      }
      
      // OCR results
      final ocrRefs = sessionRefs.where((r) => r.sourceType == 'ocr').toList();
      if (ocrRefs.isNotEmpty) {
        refsBuffer.writeln('📝 [OCR 文字提取结果]');
        for (var r in ocrRefs) {
          String snippet = r.snippet;
          if (snippet.length > 3000) snippet = '${snippet.substring(0, 3000)}...[截断]';
          refsBuffer.writeln('  $idx. ${r.title}');
          refsBuffer.writeln('$snippet');
          idx++;
        }
      }
      
      // Pending images (not yet analyzed)
      final pendingImageRefs = sessionRefs.where((r) => r.sourceType == 'pending_image').toList();
      if (pendingImageRefs.isNotEmpty) {
        refsBuffer.writeln('📷 [待处理图片 - 需要你选择分析方式]');
        for (var r in pendingImageRefs) {
          refsBuffer.writeln('${r.snippet}');
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
          // 用户API支持60K tokens
          if (snippet.length > 1500) snippet = '${snippet.substring(0, 1500)}...';
          
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
    const int agentCharBudget = 50000; // 用户API支持60K tokens
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
    final ocrAvailable = !_ocrBase.contains('your-oneapi-host') && _ocrKey.isNotEmpty;

    // Check if we have an active image in this session (either vision or ocr analyzed)
    final hasSessionImage = sessionRefs.any((r) => r.sourceType == 'vision' || r.sourceType == 'ocr');
    // Check if user just uploaded an image that hasn't been analyzed yet
    final hasUnanalyzedImage = currentSessionImagePath.isNotEmpty && 
        !sessionRefs.any((r) => r.imageId == currentSessionImagePath);

    // Check if knowledge base has content
    final hasKnowledge = _knowledgeService.hasKnowledge;
    final knowledgeOverview = hasKnowledge ? _knowledgeService.getKnowledgeOverview() : '';
    AgentDecision finalizeDecision(AgentDecision d) => _finalizeDecision(userText, d, hasKnowledge: hasKnowledge);

    // Auto-trigger hints to push tool usage proactively
    final lowerUser = userText.toLowerCase();
    final autoHints = <String>[];
    if (RegExp(r'(数据|统计|趋势|来源|权威|最新|市场|指标|分析)').hasMatch(userText)) {
      autoHints.add('检测到数据/趋势诉求 → 先 search/read_url 获取权威来源，再结合 search_knowledge/read_knowledge；缺来源禁止直接 answer。');
    }
    if (RegExp(r'(pdf|扫描|图片|截图|ocr)', caseSensitive: false).hasMatch(lowerUser)) {
      autoHints.add('检测到文件/图片/扫描 → 使用 vision 或 OCR 获取内容（PDF 优先 OCR）。');
    }
    if (RegExp(r'(计划|步骤|路线图|时间表|里程碑|方案|任务|进度|风险|预算|成本|资源)').hasMatch(userText)) {
      autoHints.add('检测到规划/执行诉求 → 先 search/knowledge 收集信息，再用 take_note 记录计划/风险，必要时 save_file 导出。');
    }
    final autoTriggerSection = autoHints.isNotEmpty
        ? 'AUTO_TRIGGER_HINTS:\\n- ${autoHints.join('\\n- ')}'
        : '';
    final deepReasoningSection = _deepReasoningMode
        ? '''
## DEEP REASONING MODE (已开启)
- 上下文要求：推理必须结合 <user_profile>、<chat_history>、<current_observations>，不可只看当前输入。
- 流程：假设/疑问 → search/read_url/search_knowledge 验证 → 生成多方案 A/B/C（每个给可行性/成本/风险评分，0-1）→ 选择方案并给行动项 → 指标与风险。
- 验证：至少一次 reflect 或 hypothesize；至少一次 search 或 search_knowledge（除非明确闲聊）；结论前再做一次校验（search/knowledge，或给出需要补充的信息）。
- 输出：来源/证据、洞察/趋势、方案对比（含评分）、最终选择理由、行动项、指标、风险与缓解。重要要点用 take_note，必要时 save_file。
- 迭代：必须回顾 <action_history> 和 <current_observations> 里的已有方案/评分/未解决点，先总结再迭代，禁止忽视前序信息。
- 禁止凭空编造，缺信息时主动说明并提出获取路径（搜索/追问）。
'''
        : '';

    final toolbelt = '''
### TOOLBELT (what you can call)
$deepReasoningSection

## ⚠️ REQUIRED JSON FIELDS FOR ALL TOOLS:
Every tool output MUST include: type, reason, confidence(0-1), continue(true/false)

**🔧 ACTION TOOLS:**

- search: ${searchAvailable ? "AVAILABLE via $resolvedSearchProvider" : "UNAVAILABLE (no search key configured; do NOT pick search)"}
  * **JSON**: {"type":"search","query":"搜索关键词","reason":"P1:...|P2:...|P3:...","confidence":0.9,"continue":true}
  * query: The search keywords (REQUIRED - NOT content!)
  * Returns: Short references/snippets from web search
  * continue: Usually true (you'll answer after seeing results)

- draw: ${drawAvailable ? "AVAILABLE (image generation)" : "UNAVAILABLE (image API not configured; do NOT pick draw)"}
  * **JSON**: {"type":"draw","content":"detailed image prompt in English","reason":"...","confidence":0.95,"continue":false}
  * content: Full image prompt (REQUIRED)
  * continue: false (image is shown to user) or true (if you want to comment)

- vision: ${visionAvailable ? "AVAILABLE - 多模态理解模型 (GPT-4V/Gemini等)" : "UNAVAILABLE (vision API not configured)"}
  * **JSON**: {"type":"vision","content":"analysis prompt","reason":"...","confidence":0.85,"continue":true}
  * **API能力**: 理解图片整体内容、场景描述、物体识别、图表解读、情感分析
  * **适用场景**: "这是什么"、"描述图片"、"分析这张图"、"图里有什么"
  * **局限性**: 文字提取不精确，可能漏字或误识别
  * NOTE: 如果 <current_observations> 已有分析结果，先看已有信息

- ocr: ${ocrAvailable ? "AVAILABLE - 专业OCR模型 (精确文字提取)" : "UNAVAILABLE (OCR API not configured)"}
  * **JSON**: {"type":"ocr","content":"optional prompt","reason":"...","confidence":0.9,"continue":true}
  * **API能力**: 精确提取图片/PDF中的所有文字，保持格式
  * **适用场景**: 文档扫描、截图文字、发票识别、表格数据、PDF转文字
  * **优势**: 文字提取准确率远高于 vision，支持 PDF 自动拆页
  * Returns: Markdown格式的提取文字

**🎯 VISION vs OCR 选择逻辑 (以用户目的为准):**
用户目的是什么？
├─ 需要**精确获取文字内容** (复制、引用、数据处理) → **ocr**
├─ 需要**理解图片含义** (这是什么、描述、分析) → **vision**
├─ 文档/PDF/截图 + 要提取信息 → **ocr** (更准确)
├─ 照片/场景/图表 + 要理解内容 → **vision** (更智能)
└─ 不确定？看图片类型：文档类→ocr，场景类→vision

${!ocrAvailable && visionAvailable ? "⚠️ OCR未配置：vision 也能提取文字，但准确率较低，文档类建议用户配置OCR" : ""}
${ocrAvailable && !visionAvailable ? "⚠️ Vision未配置：ocr 只能提取文字，无法理解图片内容/含义" : ""}

- read_url: ${searchAvailable ? "AVAILABLE - Deep read a webpage for full content" : "UNAVAILABLE (no network access)"}
  * **JSON**: {"type":"read_url","content":"https://example.com/article","reason":"...","confidence":0.85,"continue":true}
  * content: The full URL to read (REQUIRED)
  * Returns: Title + extracted main content (up to 8000 chars)
  * USE WHEN: Search gave you a relevant URL but snippet is too short
  * WORKFLOW: search → review results → read_url on promising link → answer

**📚 KNOWLEDGE BASE TOOLS (3-Step Retrieval Flow):**
${hasKnowledge ? '''
- search_knowledge: AVAILABLE - Search the knowledge base by keywords.
  * **JSON**: {"type":"search_knowledge","content":"keyword1, keyword2","reason":"...","confidence":0.8,"continue":true}
  * content: Comma-separated keywords (REQUIRED)
  * Returns: Chunk summaries WITH CHUNK IDs (e.g., "file123_0", "file123_3000")
  * ⚠️ IMPORTANT: Note down the Chunk IDs from results - you need them for read_knowledge!
  
- take_note: AVAILABLE - Save notes to temporary memory.
  * **JSON**: {"type":"take_note","content":"your notes here","reason":"...","confidence":0.9,"continue":true}
  * content: Your notes text (REQUIRED)
  * 💡 TIP: Write down relevant Chunk IDs here! e.g., "file123_0 covers auth, file123_3000 covers tokens"

- read_knowledge: AVAILABLE - Read full content of specific chunks.
  * **JSON**: {"type":"read_knowledge","content":"file123_0, file123_3000","reason":"...","confidence":0.85,"continue":true}
  * content: Comma-separated Chunk IDs from search results (REQUIRED)
  * ⚠️ CRITICAL: Use the EXACT Chunk IDs returned by search_knowledge! Format: "fileId_offset"
  * Returns: Full text content of the chunks (up to 15000 chars total)

- delete_knowledge: AVAILABLE - Delete content from knowledge base.
  * **JSON**: {"type":"delete_knowledge","content":"file_id or chunk_id","reason":"...","confidence":0.9,"continue":false}
  * content: file_id or chunk_id to delete (REQUIRED)
  * NOTE: Irreversible. Confirm with user first.

**⚠️ Knowledge Workflow - INDEX IS CRITICAL:**
1. search_knowledge → Get Chunk IDs (e.g., "doc1_0", "doc1_3000")
2. (optional) take_note → Record which Chunk IDs are relevant
3. read_knowledge → Use EXACT Chunk IDs to fetch content
4. answer → Synthesize information
Example: search returns [doc1_0, doc1_3000] → read_knowledge with "doc1_0, doc1_3000"
''' : '''
- search_knowledge: UNAVAILABLE (knowledge base is empty - no files uploaded)
- read_knowledge: UNAVAILABLE (knowledge base is empty)
- delete_knowledge: UNAVAILABLE (knowledge base is empty)
'''}

- save_file: ALWAYS AVAILABLE - Save text or code to a local file.
  * **JSON**: {"type":"save_file","filename":"code.py","content":"file content here","reason":"...","confidence":1.0,"continue":false}
  * filename: File name with extension (REQUIRED)
  * content: File content to save (REQUIRED)
  * Use when user asks to "save", "download", "create file", or "export"

- system_control: AVAILABLE - Control device global actions.
  * **JSON**: {"type":"system_control","content":"home","reason":"...","confidence":1.0,"continue":false}
  * content: One of: "home", "back", "recents", "notifications", "lock", "screenshot" (REQUIRED)
  * NOTE: Requires Accessibility Service. If action fails, ask user to enable it.

**🧠 THINKING TOOLS:**

- reflect: Pause and self-critique. Use when confused or stuck.
  * **JSON**: {"type":"reflect","content":"My analysis of this situation...","reason":"...","confidence":0.6,"continue":true}
  * content: Your reflection/analysis text (REQUIRED)
  * continue: Usually true (you'll take action after reflecting)

- hypothesize: Generate 2-3 alternative approaches.
  * **JSON**: {"type":"hypothesize","hypotheses":["approach A","approach B","approach C"],"selected_hypothesis":"approach A because...","reason":"...","confidence":0.7,"continue":true}
  * hypotheses: Array of alternative approaches (REQUIRED)
  * selected_hypothesis: Which one you chose and why (REQUIRED)
  * Use when one path fails and you need new ideas

- clarify: Ask user for missing info.
  * **JSON**: {"type":"clarify","content":"Your question to the user","reason":"...","confidence":0.5,"continue":false}
  * content: The question to ask user (REQUIRED)
  * continue: false (wait for user response)
  * Use ONLY when you truly cannot proceed without user input

**📝 OUTPUT:**

- answer: Final response to user.
  * **JSON**: {"type":"answer","content":"Your response here","reason":"...","confidence":0.95,"continue":false}
  * content: Your natural language response (REQUIRED)
  * continue: Usually false (conversation ends)
  * ⚠️ Use ONLY after gathering info with tools, or for simple greetings
${hasUnanalyzedImage ? """

⚠️ **IMAGE PENDING ANALYSIS**: User uploaded an image that needs processing!
- Check <current_observations> for the pending image marker
- You MUST choose either **ocr** (to extract text) or **vision** (to understand content)
- Base your choice on user's request and the image context
""" : hasSessionImage ? """

⚠️ **IMAGE ALREADY ANALYZED**: Check <current_observations> for vision/OCR results.
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

$deepReasoningSection

## 🧠 THREE-PASS DECISION PROCESS (CRITICAL!)
Before outputting your JSON decision, you MUST internally perform THREE rounds of thinking:

### PASS 1: INTENT UNDERSTANDING (意图理解)
- What does the user REALLY want? (not just surface request)
- What is the underlying goal or problem?
- What would make the user truly satisfied?

### PASS 2: CAPABILITY REVIEW (能力审查)
- What tools/APIs do I have available? (search, draw, vision, knowledge, reflect, hypothesize, etc.)
- Am I FULLY utilizing my capabilities?
- Is there a tool I'm FORGETTING to use?
- Am I being lazy by jumping to "answer" without gathering real info?
- Could COMBINING multiple tools give better results?

### PASS 3: OUTCOME PREDICTION (效果预判)
- If I execute this action, what will happen?
- Will the result actually satisfy the user's underlying goal (from P1)?
- Am I just "doing something" or truly ADVANCING toward the solution?
- What's the probability of success? If low, consider alternatives.

**Include your three-pass reasoning in the "reason" field:**
Example: "P1:用户想了解最新动态 | P2:search可获实时数据,已添加日期限定 | P3:高质量搜索结果将直接满足需求✓"

## ⚠️ CRITICAL RULE: TOOL-FIRST PRINCIPLE ⚠️
**BEFORE using "answer", carefully consider if ANY tool can improve your response.**

🧠 **SELF-CHECK BEFORE "answer":**
1. Is <current_observations> EMPTY or just system notes? → Tools might provide better data
2. Does user ask about facts/news/prices/events? → search usually helps
3. Does user want an image? → draw is the right choice
4. Is this a complex question? → reflect can help, then maybe search
5. ONLY for simple greetings (你好/hi/谢谢) → answer directly is fine

### HARD TRIGGERS (必须先用工具)
- 出现“数据/趋势/统计/来源/权威/最新/市场/指标/分析” → 先 search 或 read_url 拿权威来源；有文件/知识库则 search_knowledge/read_knowledge 结合引用。
- 出现“PDF/图片/扫描/文档截图” → 用 vision 或 OCR（PDF 优先 OCR）。
- 出现“计划/步骤/路线图/时间表/里程碑/方案/任务/进度/风险/预算/成本/资源” → 先 search/knowledge 收集信息，再用 take_note 记录计划/风险；必要时 save_file 导出。
- 不知道就去搜，禁止凭空编造或直接 answer。

### 结构化输出要求（当使用 answer 时）
- 必须包含：来源/证据（标注搜索或知识来源）、洞察/趋势、行动项（含负责人或下一步）、指标/衡量方式、风险与缓解。缺少来源时必须先调用 search 或 knowledge。
- 关键要点用 take_note 保存；需要文件输出时用 save_file 生成 markdown（如计划/风险/指标表）。

**SYSTEM FEEDBACK:**
- If you choose "answer" without tool usage, system will provide OBSERVATIONS (not commands)
- You can then DECIDE whether to use a tool or stick with your answer
- This is YOUR decision - system just provides information to help you think

- The user installed this app FOR THE TOOLS. Consider if tools add value.
- Review your available tools: search, draw, vision, read_url, save_file, system_control, search_knowledge, read_knowledge, reflect, hypothesize, clarify, take_note

## 🔄 ITERATIVE DECISION LOOP
You are called MULTIPLE times in a loop. Each time you see:
- <current_observations>: Results from previous tools (search results, vision analysis, etc.)
- <action_history>: What you already tried and their results

**YOUR DECISION PROCESS:**
1. **IF <current_observations> is EMPTY or minimal:**
   → This is your FIRST step. Choose a tool to gather info.
   → Questions about facts/news/data → search
   → User uploaded image → vision (but check if already analyzed in observations)
   → Complex question → reflect first, then search

2. **IF <current_observations> has search/vision/knowledge results:**
   → Review the results. Are they SUFFICIENT to answer?
   → If YES: Use "answer" with synthesized info from observations
   → If NO (need more): Use another tool (search with different keywords, read_url for details, etc.)
   → Consider: Could I enrich my answer with additional tools? (e.g., draw a diagram, save a summary)

3. **IF <action_history> shows FAILED attempts:**
   → Don't repeat the same thing! Try a different approach.
   → Multiple failed searches → hypothesize alternative angles
   → Tool returned error → try a different tool

**EXAMPLE MULTI-STEP FLOW:**
Step 1 (observations empty): {"type":"search","query":"AI news December 2024","reason":"P1:用户想了解最新AI动态 | P2:search是获取实时信息的最佳工具 | P3:搜索结果将直接满足用户需求✓","confidence":0.9,"continue":true}
Step 2 (observations have search results): {"type":"answer","content":"根据搜索结果，今天的AI新闻有...","reason":"P1:用户要最新信息 | P2:已有充分数据,无需更多工具 | P3:综合回答满足用户期望✓","confidence":0.95,"continue":false}

$toolbelt

## ⚠️ OUTPUT MUST BE PURE JSON ⚠️
Do NOT write natural language. Do NOT explain. Just output a JSON object like:
{"type":"search","query":"xxx","reason":"P1:... | P2:... | P3:...","confidence":0.8,"continue":true}

If you write anything other than JSON, the system cannot understand you!

## ✅ EXAMPLE OUTPUTS (copy these patterns!)

**User: "今天有什么新闻"**
→ {"type":"search","query":"今日新闻 2025年12月","reason":"P1:需实时数据 | P2:关键词含日期更精准 | P3:直接获取用户要的信息✓","confidence":0.9,"continue":true}

**User: "画一只猫"**
→ {"type":"draw","content":"a cute cat, digital art style, warm colors","reason":"P1:用户要图 | P2:已添加风格细节提升质量 | P3:满足用户创作需求✓","confidence":0.95,"continue":false}

**User: "帮我保存这段代码"**
→ {"type":"save_file","filename":"code.py","content":"print('hello')","reason":"P1:明确保存需求 | P2:文件名合理 | P3:完成用户任务✓","confidence":1.0,"continue":false}

**User: "回桌面"**
→ {"type":"system_control","content":"home","reason":"P1:用户要控制设备 | P2:system_control是唯一能执行此操作的工具 | P3:直接执行满足需求✓","confidence":1.0,"continue":false}

**User: "锁屏"**
→ {"type":"system_control","content":"lock","reason":"P1:锁屏需求 | P2:system_control.lock是正确工具 | P3:即时执行✓","confidence":1.0,"continue":false}

**User: "截个图"**
→ {"type":"system_control","content":"screenshot","reason":"P1:截图需求 | P2:system_control.screenshot专为此设计 | P3:立即完成✓","confidence":1.0,"continue":false}

**User: "分析一下这个问题"**
→ {"type":"reflect","content":"让我从多角度分析这个问题...","reason":"P1:用户需要深度分析 | P2:reflect适合复杂推理,后续可能需要search验证 | P3:为决策奠定思考基础✓","confidence":0.7,"continue":true}

**User: "你好"**
→ {"type":"answer","content":"你好呀！有什么可以帮你的？","reason":"P1:简单社交问候 | P2:无需工具,纯对话即可 | P3:友好回应建立连接✓","confidence":1.0,"continue":false}

## ✅ MULTI-STEP DECISION EXAMPLES (CRITICAL!)

**Scenario: User asks "今天比特币价格多少"**

*Step 1 - Observations empty:*
→ {"type":"search","query":"比特币价格 今天 2024年12月","reason":"P1:用户需要实时价格数据 | P2:search是获取实时信息的最佳工具,已加日期限定 | P3:高质量搜索将直接提供所需数据✓","confidence":0.9,"continue":true}

*Step 2 - Observations now contain search results with price info:*
→ {"type":"answer","content":"根据最新搜索结果，比特币今天的价格是...","reason":"P1:用户要价格信息 | P2:已有充分数据,所有可用工具已发挥作用 | P3:可综合回答满足用户✓","confidence":0.95,"continue":false}

**Scenario: Search returned no useful results**

*Step 1:*
→ {"type":"search","query":"obscure topic","reason":"P1:需查询信息 | P2:search是首选信息获取工具 | P3:初步尝试✓","continue":true}

*Step 2 - Observations show "Search returned 0 results":*
→ {"type":"hypothesize","content":"搜索失败,考虑:1)换同义词 2)分解问题 3)查相关领域","reason":"P1:需要新思路 | P2:hypothesize帮助生成替代方案,避免重复失败 | P3:为下一步搜索提供更好方向✓","confidence":0.6,"continue":true}

*Step 3 - After hypothesizing:*
→ {"type":"search","query":"broader topic related terms","reason":"P1:继续寻找信息 | P2:基于hypothesize的建议改进关键词 | P3:更高成功概率✓","confidence":0.7,"continue":true}

## 🚫 FORBIDDEN (These will FAIL!)
❌ "我认为需要搜索一下..." ← 这不是 JSON！
❌ "让我帮你查找..." ← 这不是 JSON！
❌ "好的，我来画一张..." ← 这不是 JSON！
❌ 任何不以 { 开头的回复！

## 📋 DECISION RULES (Apply THREE-PASS to each!)
**FIRST, check <current_observations>:**
- If observations HAVE useful results → Use "answer" to synthesize them
- If observations are EMPTY/insufficient → Use tools below:

**THEN, match user intent (P1) and review tools (P2):**
1. "最新/今天/天气/新闻/股价/多少钱" → search (实时数据)
2. "画/生成图/设计图" → draw (创意生成)
3. "保存/导出/下载" → save_file (文件操作)
4. "回桌面/返回/锁屏/截图/通知" → system_control (设备控制)
5. "分析/思考/复杂问题" → reflect (深度推理)
6. "换个角度/试试别的" → hypothesize (策略调整)
7. "你好/谢谢/再见" AND no complex question → answer (社交对话)
8. 搜索结果不够详细 → read_url (深度阅读)
9. 需要记住/保存想法 → take_note (知识积累)
10. 查询已保存知识 → search_knowledge / read_knowledge

## 🎭 PERSONA
<persona>
${_activePersona.prompt}
</persona>
回答时用这个人格语气，但工具调用不变。

## 📤 OUTPUT FORMAT: PLAN (Multi-Step) or SINGLE (One Action)

**PLAN FORMAT (for complex tasks requiring multiple API calls):**
```json
{
  "mode": "plan",
  "P1": "用户真正想要的是...",
  "P2": "将使用以下工具: search获取数据, reflect分析, answer综合回答",
  "P3": "预期达成: 用户获得全面准确的信息",
  "confidence": 0.85,
  "steps": [
    {"step": 1, "type": "search", "query": "关键词", "purpose": "获取最新数据", "output_as": "search_results"},
    {"step": 2, "type": "reflect", "content": "基于搜索结果分析...", "purpose": "深入理解", "depends_on": [1]},
    {"step": 3, "type": "answer", "content": "综合以上信息...", "purpose": "最终回答", "depends_on": [1,2]}
  ],
  "fallback": "如果搜索失败，使用知识库或直接基于已有信息回答"
}
```

**SINGLE FORMAT (for simple one-step tasks):**
```json
{
  "mode": "single",
  "type": "search",
  "query": "搜索词",
  "reason": "P1:用户需要X | P2:search最适合 | P3:将获得所需信息",
  "confidence": 0.9,
  "continue": true
}
```

**WHEN TO USE PLAN vs SINGLE:**
- PLAN: Complex questions needing multiple tools (search→read_url→answer)
- PLAN: Tasks requiring parallel API calls (search A + search B → combine)
- PLAN: Multi-phase operations (reflect→search→hypothesize→answer)
- SINGLE: Simple direct actions (greetings, system control, simple search)

**PLAN STEP FIELDS:**
- step: Step number (1, 2, 3...)
- type: Tool to use (search/draw/read_url/reflect/answer/etc.)
- query/content/filename/url: Parameters for the tool
- purpose: Why this step (brief)
- depends_on: Array of step numbers that must complete first (e.g., [1,2])
- output_as: Variable name to store result for later steps (optional)
- continue_on_fail: If true, continue plan even if this step fails

## 🚀 PLAN TRIGGER CONDITIONS (必须使用PLAN的场景)

**📋 USE PLAN MODE WHEN ANY OF THESE ARE TRUE:**
1. User asks a question needing RESEARCH + ANALYSIS + ANSWER (3+ steps)
2. User wants COMPARISON (搜索A → 搜索B → 对比分析)
3. User asks "详细分析/深入研究/全面了解" (comprehensive request)
4. Task involves MULTIPLE data sources (网络 + 知识库 + 图片)
5. User asks about pros/cons, recommendations, or complex decisions
6. First step may fail and needs fallback strategy

**📋 PLAN EXAMPLES:**

**User: "帮我对比一下iPhone和安卓手机的优缺点"**
```json
{
  "mode": "plan",
  "P1": "用户需要两个平台的客观对比分析",
  "P2": "将使用search获取两方信息,reflect整理对比,answer输出结论",
  "P3": "预期:用户获得清晰的优缺点对比表",
  "confidence": 0.85,
  "steps": [
    {"step": 1, "type": "search", "query": "iPhone优点缺点 2024", "purpose": "获取iOS平台信息"},
    {"step": 2, "type": "search", "query": "安卓手机优点缺点 2024", "purpose": "获取Android平台信息"},
    {"step": 3, "type": "reflect", "content": "整理两个平台的优缺点对比...", "purpose": "深入分析", "depends_on": [1,2]},
    {"step": 4, "type": "answer", "content": "对比分析结果...", "purpose": "最终回答", "depends_on": [3]}
  ],
  "fallback": "如果搜索失败，基于通用知识回答"
}
```

**User: "我想了解最近的AI新闻，并分析一下趋势"**
```json
{
  "mode": "plan",
  "P1": "用户要AI新闻+趋势分析(两个子任务)",
  "P2": "search获取新闻,reflect分析趋势,answer综合",
  "P3": "预期:新闻摘要+趋势洞察",
  "confidence": 0.8,
  "steps": [
    {"step": 1, "type": "search", "query": "AI新闻 2024年12月", "purpose": "获取最新新闻"},
    {"step": 2, "type": "reflect", "content": "分析这些新闻背后的趋势...", "purpose": "趋势分析", "depends_on": [1]},
    {"step": 3, "type": "answer", "content": "", "purpose": "输出新闻摘要和趋势分析", "depends_on": [1,2]}
  ]
}
```

**User: "根据我的知识库回答这个问题"**
```json
{
  "mode": "plan",
  "P1": "用户要从知识库提取信息",
  "P2": "search_knowledge找索引,read_knowledge读内容,answer回复",
  "P3": "预期:基于用户知识库的精准回答",
  "confidence": 0.9,
  "steps": [
    {"step": 1, "type": "search_knowledge", "content": "相关关键词", "purpose": "搜索知识库找到Chunk ID"},
    {"step": 2, "type": "read_knowledge", "content": "chunk_ids", "purpose": "读取完整内容", "depends_on": [1]},
    {"step": 3, "type": "answer", "content": "", "purpose": "基于知识库回答", "depends_on": [2]}
  ]
}
```

**📋 USE SINGLE MODE WHEN:**
- Simple greeting or farewell (你好/谢谢/再见)
- Single direct action (画图/搜索/保存文件/系统控制)
- User explicitly asks for ONE thing only
- <action_history> already shows progress, just need final answer

**⚠️ DEFAULT TO PLAN FOR COMPLEX QUESTIONS. When in doubt, use PLAN!**
''';

    final userPrompt = '''
<current_time>
$timeString
</current_time>

${autoTriggerSection.isNotEmpty ? '''
<auto_triggers>
$autoTriggerSection
</auto_triggers>
''' : ''}

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
      // CUMULATIVE LEARNING: Each step must include ALL necessary context:
      // 1. System prompt (agent behavior + three-pass decision framework)
      // 2. Full user context (profile, knowledge, chat history, time, etc.)
      // 3. ALL previous decisions with their results (cumulative chain)
      // 4. Current observations (accumulated from all previous actions)
      // 5. Prompt for next decision
      //
      // The model gets SMARTER with each step because it sees:
      // - What it tried before
      // - What worked/failed
      // - All accumulated information
      // - The complete context to make better decisions
      //
      final List<Map<String, dynamic>> messages = [
        {'role': 'system', 'content': systemPrompt},
      ];
      
      // Build PLAN status indicator if we have an active plan
      String planStatusSection = '';
      if (_currentPlan != null) {
        final plan = _currentPlan!;
        final remainingSteps = plan.steps.length - _currentPlanStep;
        
        if (remainingSteps <= 0) {
          // Plan completed
          planStatusSection = '''
<plan_status>
🏁 [PLAN COMPLETED]
Original Plan: ${plan.steps.length} steps
P1 (意图): ${plan.userIntent}
P2 (能力): ${plan.capabilityReview}
P3 (效果): ${plan.expectedOutcome}
所有计划步骤已执行完毕。现在请决定：
- 如果信息足够 → 输出 type: "answer" 生成最终回答
- 如果发现新需求 → 输出新的 "mode": "plan" 继续探索
</plan_status>
''';
        } else {
          // Plan in progress (but this shouldn't happen in _planAgentStep since we execute from plan directly)
          planStatusSection = '''
<plan_status>
📋 [ACTIVE PLAN]
Progress: ${_currentPlanStep}/${plan.steps.length} steps completed ($remainingSteps remaining)
P1 (意图): ${plan.userIntent}
Next Planned: Step ${_currentPlanStep + 1} - ${plan.steps[_currentPlanStep].action.name}
Note: Plan is executing. This call may be for replanning due to step failure.
</plan_status>
''';
        }
      }
      
      // ALWAYS include full context - this is the "memory" that makes the agent smarter
      // Build comprehensive context that includes EVERYTHING the model needs
      final fullContextPrompt = '''
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
$planStatusSection
<chat_history>
$contextBuffer
</chat_history>

<user_input>
$userText
</user_input>
''';

      if (previousDecisions.isNotEmpty) {
        // ===== CUMULATIVE MULTI-STEP MODE =====
        // Each step builds on all previous knowledge
        
        // First message: Complete context + step indicator
        messages.add({'role': 'user', 'content': '''$fullContextPrompt

═══════════════════════════════════════════════════════════════
📊 DECISION CHAIN STATUS: Step ${previousDecisions.length + 1}
═══════════════════════════════════════════════════════════════
You have made ${previousDecisions.length} decision(s) so far. 
Review the complete chain below to understand what you've learned.
Each step adds to your knowledge - USE IT to make SMARTER decisions.
'''});
        
        // Add each decision-result pair as assistant-user turn
        // This creates the "learning chain" - model sees its own reasoning evolve
        for (int i = 0; i < previousDecisions.length; i++) {
          final d = previousDecisions[i];
          
          // Reconstruct the decision JSON (what the model outputted)
          final decisionJson = json.encode({
            'type': d.type.name,
            'query': d.query,
            'content': d.content,
            'filename': d.filename,
            'reason': d.reason?.replaceAll(RegExp(r'\[RESULT:[^\]]+\]'), '').trim(),
            'confidence': d.confidence,
            'continue': d.continueAfter,
          });
          
          // Add as assistant message (model's own past decision)
          messages.add({'role': 'assistant', 'content': decisionJson});
          
          // Extract result from the decision
          String resultInfo = 'Action completed.';
          if (d.reason != null && d.reason!.contains('[RESULT:')) {
            final resultMatch = RegExp(r'\[RESULT:([^\]]+)\]').firstMatch(d.reason!);
            if (resultMatch != null) {
              resultInfo = resultMatch.group(1)!.trim();
            }
          }
          
          // Build result message with learning cues
          final isLastStep = i == previousDecisions.length - 1;
          String resultMessage = '''
═══ STEP ${i + 1} EXECUTION RESULT ═══
$resultInfo
''';

          if (isLastStep) {
            // Final step gets full current observations and decision prompt
            resultMessage += '''

═══════════════════════════════════════════════════════════════
📚 ACCUMULATED OBSERVATIONS (from all ${previousDecisions.length} actions)
═══════════════════════════════════════════════════════════════
${refsBuffer.toString()}

═══════════════════════════════════════════════════════════════
🎯 DECISION REQUIRED: Step ${previousDecisions.length + 1}
═══════════════════════════════════════════════════════════════
📋 CHECK OBSERVATIONS ABOVE: Look for any "系统观察反馈" - these contain helpful information.

Review everything above. Apply THREE-PASS thinking:
- P1 (意图): What does the user REALLY need?
- P2 (能力): Am I FULLY utilizing my tools? (search/draw/vision/reflect/hypothesize/read_url/knowledge...)
- P3 (效果): Will this action actually achieve the user's goal?

DECISION GUIDANCE:
- If observations contain feedback about missing data → Consider if a tool would help
- If you have SUFFICIENT data from real tool results → type: "answer"
- If you need MORE info → use appropriate tool
- If previous approach FAILED → try a DIFFERENT strategy
- YOU decide - feedback is informational, not mandatory

Output your decision as JSON:
''';
          } else {
            resultMessage += '\n[Proceeding to next step...]';
          }
          
          messages.add({'role': 'user', 'content': resultMessage});
        }
      } else {
        // ===== FIRST STEP MODE =====
        // Complete context + current observations (if any from image upload etc.)
        messages.add({'role': 'user', 'content': '''$fullContextPrompt

<current_observations>
${refsBuffer.toString().isEmpty ? 'None yet - this is the FIRST planning step.' : refsBuffer.toString()}
</current_observations>

<action_history>
${prevActionsBuffer.toString()}
</action_history>

═══════════════════════════════════════════════════════════════
🎯 FIRST DECISION REQUIRED
═══════════════════════════════════════════════════════════════
This is Step 1. Analyze the user's request and context above.

⭐ IMPORTANT: 你有两种输出模式！
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 PLAN MODE (mode: "plan") - 用于复杂多步任务:
   适用场景：
   - 用户说"研究/分析/调研..." → 需要搜索+阅读+综合
   - 用户说"比较A和B" → 需要多次搜索+对比分析
   - 用户说"写一篇关于X的报告" → 需要调研+组织+撰写
   - 任何需要2个以上步骤才能完成的任务
   
🔹 SINGLE MODE (mode: "single") - 用于单步任务:
   适用场景：
   - 简单问候 → 直接回答
   - 单一搜索问题 → 一次搜索足够
   - 简单画图请求 → 直接画图
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

💡 STEP 1 GUIDANCE:
- If <current_observations> is empty → Consider if a tool could provide useful data
- Questions about facts/news/data → search usually provides better answers
- Image requests → draw is the right tool
- Complex multi-step tasks → USE PLAN MODE (mode: "plan")
- Simple greetings → answer directly is fine

Apply THREE-PASS thinking:
- P1 (意图): What does the user REALLY want? (underlying goal)
- P2 (能力): What tools do I have? Could any of them improve my response?
- P3 (效果): Will this action lead to user satisfaction?

📌 IF THIS IS A COMPLEX TASK, OUTPUT PLAN FORMAT:
{
  "mode": "plan",
  "P1": "用户真正的需求",
  "P2": "我会使用哪些能力",
  "P3": "预期达成什么效果",
  "steps": [...]
}

📌 IF THIS IS A SIMPLE TASK, OUTPUT SINGLE FORMAT:
{
  "mode": "single",
  "type": "search/answer/draw/...",
  "query": "...",
  "reason": "..."
}

Output your decision as JSON:
'''});
      }
      
      final body = json.encode({
        'model': effectiveModel,
        'messages': messages,
        'stream': false,
        'temperature': 0.1, // Low temp for precise decision
        'max_tokens': 4096, // Ensure response isn't truncated
      });

      // 使用带重试的请求
      final resp = await _postWithRetry(
        uri,
        headers: {
          'Authorization': 'Bearer $effectiveKey',
          'Content-Type': 'application/json',
        },
        body: body,
        timeout: const Duration(minutes: 3),
        maxRetries: 2,
      );

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
            
            // Check if this is a PLAN or SINGLE mode
            final mode = parsed['mode'] as String?;
            
            if (mode == 'plan' && parsed['steps'] != null) {
              // ===== PLAN MODE: Multi-step execution =====
              debugPrint('📋 Detected PLAN mode with ${(parsed['steps'] as List).length} steps');
              
              final plan = AgentPlan.fromJson(parsed);
              _currentPlan = plan;
              _currentPlanStep = 0;
              
              // 更新推理链面板
              if (mounted) {
                setState(() {
                  _reasoningSteps = [
                    '📋 生成执行计划 (${plan.steps.length} 步)',
                    '🎯 意图: ${plan.userIntent}',
                    '🔧 能力: ${plan.capabilityReview}',
                    '✨ 预期: ${plan.expectedOutcome}',
                  ];
                  _currentReasoning = '准备执行第 1 步: ${plan.steps.first.action.name}';
                });
              }
              
              // Log the plan
              debugPrint('📋 Plan P1 (Intent): ${plan.userIntent}');
              debugPrint('📋 Plan P2 (Capability): ${plan.capabilityReview}');
              debugPrint('📋 Plan P3 (Outcome): ${plan.expectedOutcome}');
              for (var step in plan.steps) {
                debugPrint('   Step ${step.stepNumber}: ${step.action.name} - ${step.purpose}');
              }
              
                // Return the first step as AgentDecision
                if (plan.steps.isNotEmpty) {
                  final firstStep = plan.steps[0];
                  final rawDecision = AgentDecision(
                    type: firstStep.action,
                    query: firstStep.query,
                    content: firstStep.content,
                    filename: firstStep.filename,
                    reason: '[PLAN Step 1/${plan.steps.length}] ${firstStep.purpose} | P1:${plan.userIntent} | P2:${plan.capabilityReview} | P3:${plan.expectedOutcome}',
                    confidence: plan.overallConfidence,
                    continueAfter: plan.steps.length > 1, // Continue if more steps
                  );
                  return finalizeDecision(rawDecision);
                }
              }
              
              // ===== SINGLE MODE or legacy format =====
              debugPrint('✅ Successfully parsed JSON (single mode), type: ${parsed['type']}');
              _currentPlan = null; // Clear any previous plan
              _currentPlanStep = 0;
              final singleDecision = AgentDecision.fromJson(parsed);
              return finalizeDecision(singleDecision);
            } catch (jsonError) {
              debugPrint('❌ JSON parse failed: $jsonError');
              // Continue to Strategy 2
            }
          }
        
        // Strategy 2: Use Worker API to semantically parse natural language into structured intent
        // IMPORTANT: Worker parses model's "thinking" text, not user input
        // Only trust Worker if it extracts an ACTION (not just "answer")
        debugPrint('🔄 JSON parse failed, using Worker API for semantic intent extraction...');
        
        try {
          final workerDecision = await _parseIntentWithWorker(content);
            if (workerDecision != null) {
              // 🔴 CRITICAL: If Worker returns "answer", it means model just rambled text
              // In this case, we should NOT trust it and fall through to regex on USER input
              if (workerDecision.type == AgentActionType.answer) {
                debugPrint('⚠️ Worker returned "answer" (model rambling). Falling through to regex on USER input.');
                // Don't return - fall through to Strategy 3
              } else {
                debugPrint('✅ Worker extracted ACTION: ${workerDecision.type}');
                _currentPlan = null; // Clear plan for worker-parsed decisions
                return finalizeDecision(workerDecision);
              }
            }
        } catch (workerError) {
          debugPrint('⚠️ Worker intent parsing failed: $workerError, falling back to regex');
        }
        
        // Strategy 3: Fallback to regex-based extraction
        // IMPORTANT: We should analyze USER'S ORIGINAL REQUEST (userText), not model's rambling (content)
        debugPrint('🔄 Falling back to regex-based intent extraction on USER INPUT...');
        _currentPlan = null; // Clear plan for regex-parsed decisions
        
        // Use userText (user's original request) for intent detection, not model output
        final lowerUserText = userText.toLowerCase();
        
        // ====== SEARCH INTENT ======
        final searchPatterns = [
          RegExp(r'(搜索|查找|查询|搜一下|查一下|search|look up|find|去.*?找|网上.*?查|了解|获取信息|最新|今天|多少钱|价格|新闻|天气)', caseSensitive: false),
        ];
        for (var pattern in searchPatterns) {
          if (pattern.hasMatch(userText)) {
            // Extract any quoted text as query, or use user's input cleaned up
            final quoteMatch = RegExp('["\'“”]([^"\'“”]+)["\'“”]').firstMatch(userText);
            String query = quoteMatch?.group(1) ?? '';
            if (query.isEmpty) {
              // Use the user's text directly as search query
              query = userText.replaceAll(RegExp(r'(请|帮我|告诉我|我想知道|什么是|怎么|如何|呢|吗|吧)'), '').trim();
            }
            if (query.length > 80) query = query.substring(0, 80);
            if (query.isEmpty) query = userText.split(' ').first;
            debugPrint('🔍 Regex inferred SEARCH from user input: "$query"');
            return finalizeDecision(AgentDecision(
              type: AgentActionType.search,
              query: query.isNotEmpty ? query : userText,
              reason: '[REGEX-FALLBACK] Detected search intent in user query.',
              continueAfter: true,
            ));
          }
        }
        
        // ====== DRAW INTENT ======
        final drawPatterns = [
          RegExp('(画|绘制|生成图片|draw|generate image|create image)\\s*[：:"\']?(.+)', caseSensitive: false),
          RegExp('(应该|需要|可以)\\s*(画|绘制|生成)', caseSensitive: false),
        ];
        for (var pattern in drawPatterns) {
          final match = pattern.firstMatch(userText);
          if (match != null) {
            String? prompt = match.groupCount >= 2 ? match.group(2)?.trim() : null;
            if (prompt == null || prompt.isEmpty) {
              final quoteMatch = RegExp('["\'“”]([^"\'“”]+)["\'“”]').firstMatch(userText);
              prompt = quoteMatch?.group(1) ?? userText.replaceAll(RegExp(r'(画|绘制|生成|帮我|请)'), '').trim();
            }
            debugPrint('🎨 Inferred DRAW from user input: "$prompt"');
            return finalizeDecision(AgentDecision(
              type: AgentActionType.draw,
              content: prompt.isNotEmpty ? prompt : 'user requested image',
              reason: '[AUTO-INFERRED] Detected draw intent in user query.',
              continueAfter: false,
            ));
          }
        }
        
        // ====== SAVE FILE INTENT ======
        if (lowerUserText.contains('保存') || lowerUserText.contains('save') || 
            lowerUserText.contains('导出') || lowerUserText.contains('export') ||
            lowerUserText.contains('下载') || lowerUserText.contains('download')) {
          // Try to find filename
          final filenameMatch = RegExp(r'[\w\-]+\.(txt|md|py|js|json|html|css|csv)').firstMatch(userText);
          final filename = filenameMatch?.group(0) ?? 'output.txt';
          debugPrint('💾 Inferred SAVE_FILE: $filename');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.save_file,
            filename: filename,
            content: userText,
            reason: '[AUTO-INFERRED] Detected save intent.',
            continueAfter: false,
          ));
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
            if (lowerUserText.contains(keyword.toLowerCase())) {
              debugPrint('📱 Inferred SYSTEM_CONTROL: ${entry.key}');
              return finalizeDecision(AgentDecision(
                type: AgentActionType.system_control,
                content: entry.key,
                reason: '[AUTO-INFERRED] Detected system control intent.',
                continueAfter: false,
              ));
            }
          }
        }
        
        // ====== REFLECT INTENT ======
        if (lowerUserText.contains('反思') || lowerUserText.contains('思考') || 
            lowerUserText.contains('分析') || lowerUserText.contains('reflect') ||
            lowerUserText.contains('think') || lowerUserText.contains('consider')) {
          debugPrint('🤔 Inferred REFLECT');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.reflect,
            content: userText.length > 300 ? userText.substring(0, 300) : userText,
            reason: '[AUTO-INFERRED] Detected reflection/thinking intent.',
            continueAfter: true,
          ));
        }
        
        // ====== CLARIFY INTENT ======
        if (userText.contains('?') || userText.contains('？') ||
            lowerUserText.contains('请问') || lowerUserText.contains('能否告诉') ||
            lowerUserText.contains('需要更多信息') || lowerUserText.contains('clarify')) {
          // This might be a question that needs search, not clarification
          // Check if it's asking about something factual
          if (lowerUserText.contains('是什么') || lowerUserText.contains('多少') ||
              lowerUserText.contains('怎么') || lowerUserText.contains('如何') ||
              lowerUserText.contains('为什么') || lowerUserText.contains('哪里')) {
            // This is a factual question, use search
            debugPrint('🔍 Question detected, using SEARCH');
            return finalizeDecision(AgentDecision(
              type: AgentActionType.search,
              query: userText.replaceAll(RegExp(r'[\?？]'), '').trim(),
              reason: '[AUTO-INFERRED] User question detected, searching for answer.',
              continueAfter: true,
            ));
          }
        }
        
        // ====== KNOWLEDGE BASE INTENT ======
        if (lowerUserText.contains('知识库') || lowerUserText.contains('上传的文件') ||
            lowerUserText.contains('knowledge') || lowerUserText.contains('uploaded file')) {
          final keywordMatch = RegExp('["\'“”]([^"\'“”]+)["\'“”]').firstMatch(userText);
          final keywords = keywordMatch?.group(1) ?? userText.split('\n').first;
          debugPrint('📚 Inferred SEARCH_KNOWLEDGE: $keywords');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.search_knowledge,
            content: keywords,
            reason: '[AUTO-INFERRED] Detected knowledge base search intent.',
            continueAfter: true,
          ));
        }
        
        // ====== READ URL INTENT ======
        final urlMatch = RegExp(r'https?://[^\s<>"]+').firstMatch(userText);
        if (urlMatch != null) {
          final url = urlMatch.group(0)!;
          debugPrint('🌐 Inferred READ_URL: $url');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.read_url,
            content: url,
            reason: '[AUTO-INFERRED] URL detected in user input.',
            continueAfter: true,
          ));
        }
        
        // ====== VISION INTENT ======
        if (lowerUserText.contains('看图') || lowerUserText.contains('分析图') || 
            lowerUserText.contains('图片里') || lowerUserText.contains('图中') ||
            lowerUserText.contains('analyze image') || lowerUserText.contains('看看图') ||
            lowerUserText.contains('这张图') || lowerUserText.contains('图片')) {
          debugPrint('👁️ Inferred VISION');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.vision,
            content: userText,
            reason: '[AUTO-INFERRED] Detected image analysis intent.',
            continueAfter: true,
          ));
        }
        
        // ====== READ KNOWLEDGE INTENT ======
        final chunkIdMatch = RegExp(r'(chunk_\w+|读取\s*[\w_]+)').firstMatch(userText);
        if (chunkIdMatch != null || lowerUserText.contains('读取知识') || lowerUserText.contains('获取块')) {
          final chunkId = chunkIdMatch?.group(0)?.replaceAll('读取', '').trim() ?? '';
          debugPrint('📖 Inferred READ_KNOWLEDGE: $chunkId');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.read_knowledge,
            content: chunkId.isNotEmpty ? chunkId : userText,
            reason: '[AUTO-INFERRED] Detected knowledge reading intent.',
            continueAfter: true,
          ));
        }
        
        // ====== DELETE KNOWLEDGE INTENT ======
        if (lowerUserText.contains('删除知识') || lowerUserText.contains('移除') ||
            lowerUserText.contains('delete knowledge') || lowerUserText.contains('remove file')) {
          final idMatch = RegExp(r'[\w_-]+\.(txt|md|pdf|docx?)').firstMatch(userText);
          debugPrint('🗑️ Inferred DELETE_KNOWLEDGE');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.delete_knowledge,
            content: idMatch?.group(0) ?? userText,
            reason: '[AUTO-INFERRED] Detected knowledge deletion intent.',
            continueAfter: false,
          ));
        }
        
        // ====== TAKE NOTE INTENT ======
        if (lowerUserText.contains('记下') || lowerUserText.contains('记录') || 
            lowerUserText.contains('note') || lowerUserText.contains('记住')) {
          debugPrint('📝 Inferred TAKE_NOTE');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.take_note,
            content: userText,
            reason: '[AUTO-INFERRED] Detected note-taking intent.',
            continueAfter: true,
          ));
        }
        
        // ====== HYPOTHESIZE INTENT ======
        if (lowerUserText.contains('假设') || lowerUserText.contains('可能的方案') || 
            lowerUserText.contains('几种方法') || lowerUserText.contains('hypothes') ||
            lowerUserText.contains('alternatives') || lowerUserText.contains('options')) {
          debugPrint('💡 Inferred HYPOTHESIZE');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.hypothesize,
            content: userText,
            hypotheses: ['方案1', '方案2'], // Placeholder
            selectedHypothesis: '方案1',
            reason: '[AUTO-INFERRED] Detected hypothesis generation intent.',
            continueAfter: true,
          ));
        }
        
        // ====== DEFAULT: Force SEARCH for any non-trivial query ======
        // If we got here, model failed to produce JSON and no specific intent matched
        final isSimpleGreeting = userText.length < 10 && 
            (lowerUserText.contains('你好') || lowerUserText.contains('hi') || 
             lowerUserText.contains('hello') || lowerUserText.contains('谢谢') ||
             lowerUserText.contains('好的') || lowerUserText.contains('ok'));
        
        if (isSimpleGreeting) {
          debugPrint('👋 Simple greeting detected');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.answer,
            content: '',
            reason: '[GREETING] Simple greeting, no tools needed.',
          ));
        }
        
        // Check if search is available before forcing it
        if (searchAvailable) {
          // For everything else, force a search
          String searchQuery = userText.replaceAll(RegExp(r'(请|帮我|告诉我|我想知道|什么是|怎么|如何|呢|吗|吧|？|\?)'), '').trim();
          if (searchQuery.length > 80) searchQuery = searchQuery.substring(0, 80);
          if (searchQuery.isEmpty) searchQuery = userText.split(' ').take(5).join(' ');
          
          debugPrint('🔍 Default fallback: SEARCH with "$searchQuery"');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.search,
            query: searchQuery,
            reason: '[DEFAULT FALLBACK] No specific intent matched, using search.',
            continueAfter: true,
          ));
        } else {
          // No search available, fall back to direct answer
          debugPrint('📝 Default fallback: No search available, using answer');
          return finalizeDecision(AgentDecision(
            type: AgentActionType.answer,
            content: '',
            reason: '[DEFAULT FALLBACK] No search API configured, using direct answer.',
            continueAfter: false,
          ));
        }
        
      } else {
        debugPrint('❌ Agent API returned status ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      debugPrint('❌ Agent planning exception: $e');
    }
    
    // Fallback - API failed completely, still try to help user
    // Check if search is available before using it
    if (searchAvailable) {
      debugPrint('⚠️ API failed, forcing search on user query');
      String fallbackQuery = userText.replaceAll(RegExp(r'[？\?]'), '').trim();
      if (fallbackQuery.length > 60) fallbackQuery = fallbackQuery.substring(0, 60);
      
      return finalizeDecision(AgentDecision(
        type: AgentActionType.search,
        query: fallbackQuery.isNotEmpty ? fallbackQuery : 'user question',
        reason: '[API FALLBACK] API error, attempting search.',
        continueAfter: true,
      ));
    } else {
      debugPrint('⚠️ API failed and no search available, using direct answer');
      return finalizeDecision(AgentDecision(
        type: AgentActionType.answer,
        content: '',
        reason: '[API FALLBACK] API error and no search configured, using direct answer.',
        continueAfter: false,
      ));
    }
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
    
    // 初始化推理链显示
    setState(() {
      _showReasoningPanel = true;
      _reasoningSteps = ['接收用户请求...'];
      _currentReasoning = '正在分析意图...';
    });

    // 1. Handle Image Input - DON'T auto-analyze, let Agent decide between Vision and OCR
    if (_selectedImage != null) {
      // Persist the picked image
      currentSessionImagePath = await savePickedImage(_selectedImage!);
      
      setState(() {
        _messages.add(ChatMessage('user', content, localImagePath: currentSessionImagePath));
        _saveChatHistory();
        _inputCtrl.clear();
        _selectedImage = null;
        _sending = true;
        _loadingStatus = '准备处理图片...';
      });
      _scrollToBottom();
      
      _addReasoningStep('📷 检测到图片上传');

      // Check if we have historical analysis for this image
      final historicalRefs = await _refManager.getReferencesByImageId(currentSessionImagePath);
      if (historicalRefs.isNotEmpty) {
        // Found historical analysis - use it as context
        debugPrint('Found ${historicalRefs.length} historical analysis for image');
        sessionRefs.addAll(historicalRefs);
        _addReasoningStep('📚 找到历史分析记录: ${historicalRefs.length} 条');
      }

      // Determine user intent from text to help Agent decide
      final lowerContent = content.toLowerCase();
      final wantsOcr = RegExp(r'(ocr|识别|提取|读取|扫描|文字|文本|内容|转|翻译|复制)').hasMatch(lowerContent);
      final wantsVision = RegExp(r'(描述|分析|看|什么|这是|里面|场景|图片|识图|解释|理解)').hasMatch(lowerContent);
      
      // Add a pending image placeholder - Agent will decide how to analyze
      String intentHint = '';
      if (wantsOcr && !wantsVision) {
        intentHint = '💡 用户意图: 提取文字 → 建议使用 OCR';
        _addReasoningStep(intentHint);
      } else if (wantsVision && !wantsOcr) {
        intentHint = '💡 用户意图: 理解图片 → 建议使用 Vision';
        _addReasoningStep(intentHint);
      } else if (content.isEmpty) {
        intentHint = '💡 用户未说明意图 → 等待 Agent 根据图片内容决策';
        _addReasoningStep('⏳ 等待 Agent 决定分析方式 (Vision/OCR)');
      } else {
        intentHint = '💡 意图不明确 → Agent 将智能判断';
        _addReasoningStep(intentHint);
      }
      
      // Add unanalyzed image marker so Agent knows there's a pending image
      sessionRefs.add(ReferenceItem(
        title: '📷 待处理图片',
        url: currentSessionImagePath,
        snippet: '''⚠️ 图片已上传，等待你决定如何处理。
$intentHint

根据用户目的选择工具:
• 用户要**获取/复制/使用文字内容** → **ocr** (精确提取)
• 用户要**理解/描述/分析图片** → **vision** (智能理解)
• PDF/文档/截图类 → 通常 **ocr** 更合适
• 照片/场景/图表类 → 通常 **vision** 更合适

用户说: ${content.isEmpty ? "(未说明，请根据图片类型判断)" : content}''',
        sourceName: 'System',
        imageId: currentSessionImagePath,
        sourceType: 'pending_image',
      ));
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
        AgentDecision decision;
        bool isFromPlan = false;
        int planStepIndex = -1;
        
        // Check if we have an active plan with remaining steps
        if (_currentPlan != null && _currentPlanStep < _currentPlan!.steps.length) {
          // ===== PLAN MODE: Execute next step from existing plan =====
          planStepIndex = _currentPlanStep;
          final step = _currentPlan!.steps[planStepIndex];
          isFromPlan = true;
          
          setState(() {
            _loadingStatus = '执行计划 [${planStepIndex + 1}/${_currentPlan!.steps.length}]: ${step.action.name}...';
            _currentReasoning = step.purpose;
            if (!_reasoningSteps.contains('执行: ${step.action.name}')) {
              _reasoningSteps.add('执行: ${step.action.name}');
            }
          });
          debugPrint('📋 Executing plan step ${planStepIndex + 1}: ${step.action.name}');
          
          // Check dependencies - verify that dependent steps succeeded
          bool dependenciesMet = true;
          String? failedDependency;
          for (var depStep in step.dependsOn) {
            // depStep is 1-indexed, sessionDecisions contains results
            if (depStep > sessionDecisions.length) {
              dependenciesMet = false;
              failedDependency = 'Step $depStep not yet executed';
              break;
            }
            // Check if the dependent step failed
            final depDecision = sessionDecisions[depStep - 1];
            if (depDecision.reason?.contains('FAILED') == true || 
                depDecision.reason?.contains('error') == true ||
                depDecision.reason?.contains('returned 0') == true) {
              dependenciesMet = false;
              failedDependency = 'Step $depStep failed: ${depDecision.reason}';
              break;
            }
          }
          
          if (!dependenciesMet) {
            debugPrint('⚠️ Step ${planStepIndex + 1} dependency failed: $failedDependency');
            
            if (step.continueOnFail) {
              // Skip this step but continue plan
              debugPrint('⏭️ Skipping step ${planStepIndex + 1} (continue_on_fail=true)');
              _currentPlanStep++;
              continue;
            } else {
              // Dependency failed, need to REPLAN
              debugPrint('🔄 Dependency failed, triggering REPLAN...');
              
              // Add failure note to refs so model can see what happened
              sessionRefs.add(ReferenceItem(
                title: '⚠️ 计划执行中断',
                url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                snippet: '原计划步骤 ${planStepIndex + 1} 无法执行，依赖条件未满足: $failedDependency\n\n原计划: P1:${_currentPlan!.userIntent} | P2:${_currentPlan!.capabilityReview}\n\n请根据当前情况重新规划。',
                sourceName: 'System',
                sourceType: 'system_note',
              ));
              
              // Clear plan and let model replan
              _currentPlan = null;
              _currentPlanStep = 0;
              
              // Fall through to normal planning mode
              setState(() => _loadingStatus = '正在重新规划 (Step ${steps + 1})...');
              decision = await _planAgentStep(effectiveUserText, sessionRefs, sessionDecisions);
              isFromPlan = false;
            }
          } else {
            // Dependencies met, create decision from plan step
            decision = AgentDecision(
              type: step.action,
              query: step.query,
              content: step.content,
              filename: step.filename,
              reason: '[PLAN ${planStepIndex + 1}/${_currentPlan!.steps.length}] ${step.purpose}',
              confidence: _currentPlan!.overallConfidence,
              continueAfter: true, // Let plan control continuation
            );
            
            _currentPlanStep++;
          }
        } else {
          // ===== NORMAL MODE: Get next decision from API =====
          // This also handles replanning after plan completion or failure
          setState(() => _loadingStatus = '正在规划 (Step ${steps + 1})...');
          decision = await _planAgentStep(effectiveUserText, sessionRefs, sessionDecisions);
          
          // If a new plan was created, reset the step counter
          if (_currentPlan != null && _currentPlanStep == 0) {
            // Plan was just created in _planAgentStep, first step is already returned
            _currentPlanStep = 1;
            isFromPlan = true;
            planStepIndex = 0;
          }
        }
        
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

        // B. Act (Execute Decision) - with plan-aware result handling
        bool stepSucceeded = true;
        String stepResult = '';
        
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
                stepSucceeded = true;
                stepResult = 'Found ${uniqueNewRefs.length} results';
                
                // 更新推理链
                setState(() {
                  _reasoningSteps.add('✅ 搜索 "${decision.query}" 返回 ${uniqueNewRefs.length} 条结果');
                });
                
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
              stepSucceeded = false;
              stepResult = 'Search returned 0 results';
              
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
                reason: '${decision.reason} [RESULT: FAILED - Search #$searchAttempt returned 0 results. Suggestions: 1) Use different keywords 2) Broaden query 3) Try English terms]',
              );
              
              // 🔴 PLAN SELF-ADJUSTMENT: If this was from a plan, trigger replanning
              if (isFromPlan && _currentPlan != null) {
                debugPrint('🔄 Plan step failed (search 0 results), triggering REPLAN...');
                sessionRefs.add(ReferenceItem(
                  title: '🔄 计划调整通知',
                  url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                  snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: $stepResult\n原计划 P1 意图: ${_currentPlan!.userIntent}\n请根据当前情况调整计划。',
                  sourceName: 'System',
                  sourceType: 'system_note',
                ));
                _currentPlan = null;
                _currentPlanStep = 0;
                steps++;
                continue; // Let next iteration call _planAgentStep to replan
              }
              
              // Check if we've had too many empty searches
              final emptySearches = sessionDecisions.where((d) => 
                d.type == AgentActionType.search && d.reason?.contains('[RESULT:') == true && d.reason?.contains('returned 0') == true
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
            stepSucceeded = false;
            stepResult = 'Search error: $searchError';
            
            // 更新推理面板
            if (mounted) {
              setState(() {
                _reasoningSteps.add('❌ 搜索失败: ${decision.query}');
                _currentReasoning = '正在考虑备选方案...';
              });
            }
            
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
              reason: '${decision.reason} [RESULT: FAILED - Search error - $searchError. Agent should try alternatives.]',
            );
            
            // 🔴 PLAN SELF-ADJUSTMENT: If from plan, trigger replanning
            if (isFromPlan && _currentPlan != null) {
              debugPrint('🔄 Plan step failed (search error), triggering REPLAN...');
              sessionRefs.add(ReferenceItem(
                title: '🔄 计划调整通知',
                url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: $stepResult\n搜索服务异常，请调整策略（如使用知识库或直接回答）。',
                sourceName: 'System',
                sourceType: 'system_note',
              ));
              _currentPlan = null;
              _currentPlanStep = 0;
              steps++;
              continue;
            }
            
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
          
          // 🔒 Pre-check: Network access requires search API to be configured
          final prefs = await SharedPreferences.getInstance();
          final hasNetworkAccess = (prefs.getString('exa_key') ?? '').isNotEmpty ||
                                   (prefs.getString('you_key') ?? '').isNotEmpty ||
                                   (prefs.getString('brave_key') ?? '').isNotEmpty;
          if (!hasNetworkAccess) {
            debugPrint('⚠️ read_url requested but no network API configured');
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 网页读取失败',
              url: 'internal://error/read_url-no-api/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '无法读取网页：未配置搜索/网络API。\n请在设置中配置 Exa、You.com 或 Brave Search API。',
              sourceName: 'System',
              sourceType: 'feedback',
            ));
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.read_url,
              content: url,
              reason: '${decision.reason} [RESULT: FAILED - No network API configured. Cannot access web.]',
            );
            steps++;
            continue;
          }
          
          setState(() {
            _loadingStatus = '正在阅读网页内容...';
            _currentReasoning = '读取: $url';
          });
          debugPrint('Agent reading URL: $url');
          
          try {
            final urlRef = await _refManager.fetchUrlContent(url);
            
            // Check if fetch was successful
            if ((urlRef.reliability ?? 0.0) > 0.0) {
              // Success - add to session refs
              sessionRefs.add(urlRef);
              stepSucceeded = true;
              stepResult = 'Read ${urlRef.snippet.length} chars from ${urlRef.sourceName}';
              
              // 更新推理链
              if (mounted) {
                setState(() {
                  _reasoningSteps.add('✅ 读取网页 "${urlRef.title}" (${urlRef.snippet.length} 字符)');
                });
              }
              
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
              stepSucceeded = false;
              stepResult = 'Failed to read URL: ${urlRef.snippet}';
              
              // 更新推理链
              if (mounted) {
                setState(() {
                  _reasoningSteps.add('❌ 读取网页失败: $url');
                });
              }
              
              sessionRefs.add(urlRef); // Still add error ref for Agent awareness
              sessionDecisions.last = AgentDecision(
                type: AgentActionType.read_url,
                content: url,
                reason: '${decision.reason} [RESULT: FAILED to read URL. Error: ${urlRef.snippet}]',
              );
              
              // 🔴 PLAN SELF-ADJUSTMENT: If from plan, trigger replanning
              if (isFromPlan && _currentPlan != null) {
                debugPrint('🔄 Plan step failed (URL read failed), triggering REPLAN...');
                sessionRefs.add(ReferenceItem(
                  title: '🔄 计划调整通知',
                  url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                  snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: 无法读取URL $url\n请调整策略（如搜索其他来源或使用已有信息）。',
                  sourceName: 'System',
                  sourceType: 'system_note',
                ));
                _currentPlan = null;
                _currentPlanStep = 0;
                steps++;
                continue;
              }
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
            stepSucceeded = false;
            stepResult = 'URL read exception: $e';
            
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.read_url,
              content: url,
              reason: '${decision.reason} [RESULT: FAILED - Exception - $e]',
            );
            
            // 🔴 PLAN SELF-ADJUSTMENT: If from plan, trigger replanning
            if (isFromPlan && _currentPlan != null) {
              debugPrint('🔄 Plan step failed (URL exception), triggering REPLAN...');
              sessionRefs.add(ReferenceItem(
                title: '🔄 计划调整通知',
                url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: URL读取异常 - $e\n请调整策略。',
                sourceName: 'System',
                sourceType: 'system_note',
              ));
              _currentPlan = null;
              _currentPlanStep = 0;
              steps++;
              continue;
            }
            
            // Fallback to answer
            setState(() => _loadingStatus = '网页读取失败，正在回答...');
            await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
            break;
          }
        } 
        else if (decision.type == AgentActionType.draw && decision.content != null) {
          // Action: Draw
          
          // 🔒 Pre-check: Is Draw API configured?
          if (_imgBase.contains('your-oneapi-host') || _imgKey.isEmpty) {
            debugPrint('⚠️ draw requested but Draw API not configured');
            if (mounted) {
              setState(() {
                _reasoningSteps.add('❌ 生图API未配置');
              });
            }
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 图片生成失败',
              url: 'internal://error/draw-no-api/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '无法生成图片：未配置生图API。\n请在设置中配置图片生成API（如 DALL-E）。\n建议：告知用户需要先配置API。',
              sourceName: 'System',
              sourceType: 'feedback',
            ));
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.draw,
              content: decision.content,
              reason: '${decision.reason} [RESULT: FAILED - Draw API not configured. Cannot generate images.]',
            );
            steps++;
            continue;
          }
          
          setState(() {
            _loadingStatus = '正在生成图片...';
            _currentReasoning = '绘制: ${decision.content!.length > 30 ? decision.content!.substring(0, 30) + "..." : decision.content}';
          });
          final generatedPath = await _performImageGeneration(decision.content!, addUserMessage: false, manageSendingState: false);
          if (generatedPath != null) {
            // 更新推理链
            if (mounted) {
              setState(() {
                _reasoningSteps.add('✅ 图片生成成功');
              });
            }
            
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
            stepSucceeded = false;
            stepResult = 'Image generation failed';
            
            final failedPrompt = decision.content ?? '';
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.draw,
              content: decision.content,
              reason: '${decision.reason} [RESULT: FAILED - Draw FAILED. Possible causes: 1) Invalid prompt 2) Content policy violation 3) API error. Prompt was: "${failedPrompt.length > 50 ? failedPrompt.substring(0, 50) + "..." : failedPrompt}"]',
            );
            
            // 🔴 PLAN SELF-ADJUSTMENT: If from plan, trigger replanning
            if (isFromPlan && _currentPlan != null) {
              debugPrint('🔄 Plan step failed (draw failed), triggering REPLAN...');
              sessionRefs.add(ReferenceItem(
                title: '🔄 计划调整通知',
                url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: 图片生成失败\n提示词: "${failedPrompt.length > 100 ? failedPrompt.substring(0, 100) + "..." : failedPrompt}"\n请调整策略（如修改提示词或告知用户）。',
                sourceName: 'System',
                sourceType: 'system_note',
              ));
              _currentPlan = null;
              _currentPlanStep = 0;
              steps++;
              continue;
            }
            
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
          const maxTotalChars = 40000; // 用户API支持60K tokens
          
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
            stepSucceeded = false;
            stepResult = 'All knowledge chunks not found';
            
            final availableIds = _knowledgeService.getAllChunkIds();
            final suggestion = availableIds.isNotEmpty 
                ? 'Available IDs: ${availableIds.take(5).join(", ")}${availableIds.length > 5 ? "..." : ""}'
                : 'Knowledge base is empty.';
            resultMsg = 'FAILED - All chunks NOT FOUND: ${failedReads.join(", ")}. $suggestion';
            
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 知识库查询失败',
              url: 'internal://knowledge/error',
              snippet: 'Requested chunks not found.\n$suggestion',
              sourceName: 'KnowledgeBase',
              sourceType: 'system_note',
            ));
            
            // 🔴 PLAN SELF-ADJUSTMENT
            if (isFromPlan && _currentPlan != null) {
              debugPrint('🔄 Plan step failed (knowledge not found), triggering REPLAN...');
              sessionRefs.add(ReferenceItem(
                title: '🔄 计划调整通知',
                url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: 知识库内容未找到\n请调整策略（如使用search_knowledge搜索或使用其他工具）。',
                sourceName: 'System',
                sourceType: 'system_note',
              ));
              _currentPlan = null;
              _currentPlanStep = 0;
            }
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
          setState(() {
            _loadingStatus = '正在搜索知识库...';
            _currentReasoning = '搜索知识库: ${decision.content}';
          });
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
            
            // Collect all chunk IDs for easy reference
            final chunkIdList = results.map((r) => r['id'] as String).toList();
            resultBuffer.writeln('📋 Available Chunk IDs: ${chunkIdList.join(', ')}');
            resultBuffer.writeln('   ↳ Use these IDs with read_knowledge to get full content!\n');
            
            for (var result in results) {
              resultBuffer.writeln('━━━━━━━━━━━━━━━━━━━━');
              resultBuffer.writeln('📄 File: ${result['filename']}');
              resultBuffer.writeln('🔖 Chunk ID: ${result['id']} ← Use this ID for read_knowledge');
              resultBuffer.writeln('🎯 Match Score: ${result['score']} keyword(s)');
              resultBuffer.writeln('📝 Summary: ${result['summary']}');
            }
            
            if (hasMore) {
              resultBuffer.writeln('\n⏳ More results available: $remainingCount remaining');
              resultBuffer.writeln('💡 Use search_knowledge with same keywords to see next batch.');
              resultBuffer.writeln('💡 Or use read_knowledge with IDs: ${chunkIdList.join(', ')}');
            } else {
              resultBuffer.writeln('\n✅ All $totalMatches results shown.');
              resultBuffer.writeln('💡 Next: Use read_knowledge with content="${chunkIdList.join(', ')}" to read full content.');
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
          
          // 更新推理链
          if (mounted) {
            setState(() {
              _reasoningSteps.add('📚 知识库搜索 "$keywords": 找到 $totalMatches 条结果');
            });
          }
          
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
          setState(() {
            _loadingStatus = '正在记录笔记...';
            _currentReasoning = '记录笔记...';
          });
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
          
          // 更新推理链
          if (mounted) {
            setState(() {
              _reasoningSteps.add('📝 记录笔记 #$noteCount');
            });
          }
          
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
          setState(() {
            _loadingStatus = '正在保存文件: ${decision.filename}...';
            _currentReasoning = '保存文件: ${decision.filename}';
          });
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
             stepSucceeded = false;
             stepResult = 'File save cancelled or failed';
             
             sessionDecisions.last = AgentDecision(
                type: AgentActionType.save_file,
                filename: decision.filename,
                content: decision.content,
                reason: '${decision.reason} [RESULT: FAILED - File save cancelled or failed]',
                continueAfter: decision.continueAfter,
             );
             
             // 🔴 PLAN SELF-ADJUSTMENT
             if (isFromPlan && _currentPlan != null) {
               debugPrint('🔄 Plan step failed (save_file failed), triggering REPLAN...');
               sessionRefs.add(ReferenceItem(
                 title: '🔄 计划调整通知',
                 url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                 snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: 文件保存失败\n请调整策略（如询问用户或使用其他工具）。',
                 sourceName: 'System',
                 sourceType: 'system_note',
               ));
               _currentPlan = null;
               _currentPlanStep = 0;
               steps++;
               continue;
             }
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
          setState(() {
            _loadingStatus = '正在执行系统操作: $action...';
            _reasoningSteps.add('🔧 系统控制: $action');
            _currentReasoning = '正在执行系统操作...';
          });
          
          // Check service status first
          final isEnabled = await SystemControl.isServiceEnabled();
          if (!isEnabled) {
             // Service not enabled - ask user
             stepSucceeded = false;
             stepResult = 'Accessibility Service not enabled';
             
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
             
             // 🔴 PLAN SELF-ADJUSTMENT
             if (isFromPlan && _currentPlan != null) {
               debugPrint('🔄 Plan step failed (system_control no permission), triggering REPLAN...');
               sessionRefs.add(ReferenceItem(
                 title: '🔄 计划调整通知',
                 url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                 snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: 系统控制需要权限\n请调整策略（告知用户需要授权）。',
                 sourceName: 'System',
                 sourceType: 'system_note',
               ));
               _currentPlan = null;
               _currentPlanStep = 0;
               steps++;
               continue;
             }
             
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
          } else {
             // 🔴 PLAN SELF-ADJUSTMENT for failed system control
             if (isFromPlan && _currentPlan != null) {
               debugPrint('🔄 Plan step failed (system_control failed), triggering REPLAN...');
               sessionRefs.add(ReferenceItem(
                 title: '🔄 计划调整通知',
                 url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                 snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: 系统操作 $action 失败\n请调整策略。',
                 sourceName: 'System',
                 sourceType: 'system_note',
               ));
               _currentPlan = null;
               _currentPlanStep = 0;
               steps++;
               continue;
             }
          }
          
          if (!decision.continueAfter) break;
          steps++;
          continue;
        }
        else if (decision.type == AgentActionType.vision && currentSessionImagePath != null) {
          // Action: Additional Vision Analysis (with custom prompt)
          
          // 🔒 Pre-check: Is Vision API configured? (with fallback to Chat API)
          final visionApiConfigured = !_visionBase.contains('your-oneapi-host') && _visionKey.isNotEmpty;
          final chatApiConfigured = !_chatBase.contains('your-oneapi-host') && _chatKey.isNotEmpty;
          if (!visionApiConfigured && !chatApiConfigured) {
            debugPrint('⚠️ vision requested but neither Vision nor Chat API configured');
            sessionRefs.add(ReferenceItem(
              title: '⚠️ 图片分析失败',
              url: 'internal://error/vision-no-api/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '无法分析图片：未配置识图API或聊天API。\n请在设置中至少配置一个支持视觉的模型。',
              sourceName: 'System',
              sourceType: 'feedback',
            ));
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.vision,
              content: decision.content,
              reason: '${decision.reason} [RESULT: FAILED - No Vision/Chat API configured. Cannot analyze images.]',
            );
            steps++;
            continue;
          }
          
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
              // Remove pending_image marker since we've analyzed it
              sessionRefs.removeWhere((r) => r.sourceType == 'pending_image' && r.imageId == currentSessionImagePath);
              
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
            stepSucceeded = false;
            stepResult = 'Vision exception: $visionError';
            
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.vision,
              content: decision.content,
              reason: '${decision.reason} [RESULT: FAILED - Vision failed - $visionError. Consider: 1) Different prompt 2) Fallback to describe without analysis]',
            );
            
            // 🔴 PLAN SELF-ADJUSTMENT
            if (isFromPlan && _currentPlan != null) {
              debugPrint('🔄 Plan step failed (vision error), triggering REPLAN...');
              sessionRefs.add(ReferenceItem(
                title: '🔄 计划调整通知',
                url: 'internal://plan/replan/${DateTime.now().millisecondsSinceEpoch}',
                snippet: '原计划步骤 ${planStepIndex + 1} 执行失败: 图片分析异常 - $visionError\n请调整策略。',
                sourceName: 'System',
                sourceType: 'system_note',
              ));
              _currentPlan = null;
              _currentPlanStep = 0;
            }
            // Continue loop - Agent will decide next action based on failure
          }
          steps++;
          continue; // Always continue after vision to let Agent decide next action
        }
        else if (decision.type == AgentActionType.ocr) {
          // Action: OCR - Extract text from image
          _addReasoningStep('📝 执行 OCR 文字提取...');
          
          if (currentSessionImagePath == null || currentSessionImagePath.isEmpty) {
            _addReasoningStep('❌ OCR 失败: 没有待处理的图片');
            sessionRefs.add(ReferenceItem(
              title: '⚠️ OCR 失败',
              url: 'internal://error/ocr-no-image/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '没有待处理的图片。请先上传图片再使用 OCR。',
              sourceName: 'System',
              sourceType: 'feedback',
            ));
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.ocr,
              content: decision.content,
              reason: '${decision.reason} [RESULT: FAILED - No image to OCR]',
            );
            steps++;
            continue;
          }
          
          if (_ocrBase.contains('your-oneapi-host') || _ocrKey.isEmpty) {
            _addReasoningStep('❌ OCR 失败: 未配置 OCR API');
            sessionRefs.add(ReferenceItem(
              title: '⚠️ OCR 未配置',
              url: 'internal://error/ocr-no-api/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '无法执行 OCR：未配置 OCR API。\n请在设置中配置 OCR 服务。',
              sourceName: 'System',
              sourceType: 'feedback',
            ));
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.ocr,
              content: decision.content,
              reason: '${decision.reason} [RESULT: FAILED - No OCR API configured]',
            );
            steps++;
            continue;
          }
          
          setState(() => _loadingStatus = '正在 OCR 提取文字...');
          try {
            final customPrompt = decision.content ?? '<|grounding|>OCR this image. Extract all text.';
            final filePath = currentSessionImagePath;
            final ext = filePath.toLowerCase().split('.').last;
            
            String? ocrText;
            if (ext == 'pdf') {
              // PDF: Use PDF OCR with page splitting
              _addReasoningStep('📄 检测到 PDF，正在逐页 OCR...');
              ocrText = await _runPdfOcr(File(filePath), prompt: customPrompt);
            } else {
              // Image: Use direct image OCR
              final imageFile = File(filePath);
              ocrText = await _runImageOcr(imageFile, prompt: customPrompt);
            }
            
            if (ocrText != null && ocrText.trim().isNotEmpty) {
              _addReasoningStep('✅ OCR 成功: 提取到 ${ocrText.length} 字符');
              
              // Remove pending_image marker
              sessionRefs.removeWhere((r) => r.sourceType == 'pending_image' && r.imageId == currentSessionImagePath);
              
              // Add OCR result as reference
              sessionRefs.add(ReferenceItem(
                title: '📝 OCR 文字提取结果',
                url: currentSessionImagePath,
                snippet: ocrText,
                sourceName: 'OCR',
                imageId: currentSessionImagePath,
                sourceType: 'ocr',
              ));
              await _refManager.addExternalReferences([sessionRefs.last]);
              
              final previewText = ocrText.length > 150 ? '${ocrText.substring(0, 150)}...' : ocrText;
              sessionDecisions.last = AgentDecision(
                type: AgentActionType.ocr,
                content: customPrompt,
                reason: '${decision.reason} [RESULT: OCR success. Extracted text preview: $previewText]',
              );
            } else {
              _addReasoningStep('⚠️ OCR 未提取到文字');
              sessionRefs.add(ReferenceItem(
                title: '⚠️ OCR 无结果',
                url: 'internal://ocr-empty/${DateTime.now().millisecondsSinceEpoch}',
                snippet: 'OCR 未能从图片中提取到文字。可能原因:\n1. 图片中没有文字\n2. 图片质量太低\n3. 文字不清晰\n\n建议: 尝试使用 vision 工具来理解图片内容。',
                sourceName: 'System',
                sourceType: 'feedback',
              ));
              sessionDecisions.last = AgentDecision(
                type: AgentActionType.ocr,
                content: customPrompt,
                reason: '${decision.reason} [RESULT: OCR returned empty - image may not contain readable text. Try vision instead.]',
              );
            }
          } catch (ocrError) {
            _addReasoningStep('❌ OCR 失败: $ocrError');
            debugPrint('OCR failed: $ocrError');
            
            sessionRefs.add(ReferenceItem(
              title: '⚠️ OCR 异常',
              url: 'internal://error/ocr/${DateTime.now().millisecondsSinceEpoch}',
              snippet: 'OCR 处理失败: $ocrError\n\n建议: 检查图片格式是否支持，或尝试使用 vision 工具。',
              sourceName: 'System',
              sourceType: 'feedback',
            ));
            sessionDecisions.last = AgentDecision(
              type: AgentActionType.ocr,
              content: decision.content,
              reason: '${decision.reason} [RESULT: FAILED - OCR error: $ocrError. Consider using vision instead.]',
            );
          }
          steps++;
          continue; // Always continue after OCR to let Agent process the result
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
          
          // 更新推理链
          if (mounted) {
            setState(() {
              _reasoningSteps.add('🤔 深度反思');
            });
          }
          
          // Reflect always continues to next action
          // (Agent will decide what to do based on reflection)
          steps++;
          continue; // Continue loop to let Agent decide next action
        }
        else if (decision.type == AgentActionType.hypothesize) {
          // Action: Multi-Hypothesis Generation (Deep Think)
          final hypothesesList = decision.hypotheses ?? ['默认方案'];
          final selected = decision.selectedHypothesis ?? hypothesesList.first;
          
          setState(() {
            _loadingStatus = '💡 假设: ${selected.length > 15 ? selected.substring(0, 15) + "..." : selected}';
            _currentReasoning = '生成假设方案...';
          });
          debugPrint('Agent hypothesizing: ${decision.hypotheses}');
          
          // Artificial delay
          await Future.delayed(const Duration(milliseconds: 1200));
          
          // 更新推理链
          if (mounted) {
            setState(() {
              _reasoningSteps.add('💡 假设分析: 生成 ${hypothesesList.length} 个方案');
            });
          }
          
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
          setState(() {
            _loadingStatus = '❓ 需要您提供更多信息...';
            _reasoningSteps.add('❓ 请求澄清: 需要更多信息');
            _currentReasoning = '等待用户回复...';
          });
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
        else if (decision.type == AgentActionType.vision && currentSessionImagePath == null) {
          // ⚠️ Vision requested but NO IMAGE available - this is an error!
          debugPrint('⚠️ Vision requested but no image available');
          stepSucceeded = false;
          stepResult = 'Vision failed: No image in current session';
          
          sessionDecisions.last = AgentDecision(
            type: AgentActionType.vision,
            content: decision.content,
            reason: '${decision.reason} [RESULT: FAILED - No image available. User must send an image first.]',
          );
          
          sessionRefs.add(ReferenceItem(
            title: '⚠️ 图片分析失败',
            url: 'internal://error/vision-no-image/${DateTime.now().millisecondsSinceEpoch}',
            snippet: '无法执行图片分析：当前会话没有图片。\n请提示用户发送图片，或使用其他工具（如search）获取信息。',
            sourceName: 'System',
            sourceType: 'system_note',
          ));
          
          // 🔴 PLAN SELF-ADJUSTMENT
          if (isFromPlan && _currentPlan != null) {
            debugPrint('🔄 Plan step failed (vision no image), triggering REPLAN...');
            _currentPlan = null;
            _currentPlanStep = 0;
          }
          
          steps++;
          continue; // Let Agent try alternative approach
        }
        else if (decision.type == AgentActionType.answer) {
          // Action: Answer
          
          // 更新推理链
          if (mounted) {
            setState(() {
              _currentReasoning = '准备生成最终回答...';
            });
          }
          
          // 🧠 SMART FEEDBACK: Instead of forcing, provide feedback and let Agent decide
          final isSimpleGreeting = content.length < 10 && 
            (content.contains('你好') || content.contains('hi') || content.contains('hello') ||
             content.contains('谢谢') || content.contains('再见') || content.contains('好的'));
          
          // Check if any REAL tools were used (not just reflect/hypothesize which are thinking tools)
          final hasRealToolsUsed = sessionDecisions.any((d) => 
            d.type == AgentActionType.search ||
            d.type == AgentActionType.draw ||
            d.type == AgentActionType.vision ||
            d.type == AgentActionType.ocr ||
            d.type == AgentActionType.read_url ||
            d.type == AgentActionType.search_knowledge ||
            d.type == AgentActionType.read_knowledge ||
            d.type == AgentActionType.save_file ||
            d.type == AgentActionType.system_control);
          
          // Check if we have real data from tools (not just system notes)
          final hasRealData = sessionRefs.any((r) => 
            r.sourceType != 'system_note' && 
            r.sourceType != 'system_command' &&
            r.sourceType != 'system' &&
            r.sourceType != 'feedback');
          
          // Count feedback attempts (not "blocks", just feedback)
          final feedbackAttempts = sessionDecisions.where((d) => 
            d.reason?.contains('[FEEDBACK]') == true
          ).length;
          
          // Determine if we should provide feedback or allow the answer
          final shouldProvideToolFeedback = !isSimpleGreeting && 
            !hasRealToolsUsed && 
            !hasRealData && 
            feedbackAttempts < 2 &&  // Only give feedback twice max
            steps < maxSteps - 2;
          
          if (shouldProvideToolFeedback) {
            // 🧠 FEEDBACK MODE: Tell Agent what we observed, let it decide
            debugPrint('💡 FEEDBACK: Agent chose answer without tools. Providing observation for reconsideration.');
            setState(() => _loadingStatus = '🧠 Agent 正在重新评估...');
            
            // Provide observation feedback - NOT a command, just information
            sessionRefs.add(ReferenceItem(
              title: '💡 系统观察反馈 (非强制)',
              url: 'internal://feedback/observation/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '''[OBSERVATION - Agent 请自行判断]

你选择了直接回答，但系统观察到：
• 当前 <current_observations> 中没有来自工具的真实数据
• 用户问题: "$content"

可能的情况分析：
1. 如果这是一个需要实时信息的问题（新闻、价格、天气等）→ search 可能更好
2. 如果这是一个创作请求（画图等）→ draw 是正确选择
3. 如果这确实是一个可以直接回答的问题（常识、简单计算等）→ 继续 answer 是合理的
4. 如果问题复杂需要思考 → reflect 可以帮助理清思路

请根据你对用户问题的理解，自行决定：
- 坚持使用 "answer"（如果你确信不需要工具）
- 或改用其他工具（如果你认为工具能提供更好的回答）

这不是强制命令，是帮助你做出更好决策的反馈。''',
              sourceName: 'SystemFeedback',
              sourceType: 'feedback',
            ));
            
            // Record this as a feedback (not a block/override)
            sessionDecisions.add(AgentDecision(
              type: AgentActionType.reflect,
              content: '系统提供了观察反馈，Agent 正在重新评估决策',
              reason: '[FEEDBACK] Observation provided. Agent will reconsider. User: "$content"',
            ));
            
            steps++;
            continue;
          }
          
          // Deep Think: Check confidence before answering
          if (decision.needsMoreWork && steps < maxSteps - 2) {
            // Confidence too low - provide feedback instead of forcing
            debugPrint('💡 FEEDBACK: Confidence ${decision.confidence} is low.');
            setState(() => _loadingStatus = '🧠 Agent 置信度较低，正在重新评估...');
            
            // Provide confidence feedback
            sessionRefs.add(ReferenceItem(
              title: '💡 置信度反馈',
              url: 'internal://feedback/confidence/${DateTime.now().millisecondsSinceEpoch}',
              snippet: '''[CONFIDENCE OBSERVATION]

你的回答置信度为 ${((decision.confidence ?? 0.5) * 100).toInt()}%，系统观察到这可能不够确定。

不确定性: ${decision.uncertainties?.join(", ") ?? "未明确指出"}

建议（非强制）：
• 如果不确定事实 → search 可以获取更可靠的信息
• 如果逻辑复杂 → reflect 可以帮助理清思路
• 如果你认为当前置信度已足够 → 继续 answer 也可以

请自行判断是否需要额外的工具来提高回答质量。''',
              sourceName: 'SystemFeedback',
              sourceType: 'feedback',
            ));
            
            // Continue loop to let Agent reconsider
            steps++;
            continue;
          }
          
          // Agent decided to answer - execute it
          setState(() {
            _loadingStatus = '正在撰写回复...';
            _reasoningSteps.add('✅ 生成最终回答');
            _currentReasoning = '正在撰写回复...';
          });
          await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
          
          // Clean up plan state after answer
          _currentPlan = null;
          _currentPlanStep = 0;
          
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
        // 清理 Plan 状态
        _currentPlan = null;
        _currentPlanStep = 0;
        await _performChatRequest(content, localImage: currentSessionImagePath, references: sessionRefs, manageSendingState: false);
      }

    } catch (e) {
      _showError('Agent Error: $e');
      // 出错时也清理 Plan 状态
      _currentPlan = null;
      _currentPlanStep = 0;
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _loadingStatus = '';
        });
        // 延迟隐藏推理链面板 (移到 setState 外部)
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && !_sending) {
            setState(() {
              _showReasoningPanel = false;
              _reasoningSteps = [];
              _currentReasoning = '';
            });
          }
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
    // 等待初始化完成
    if (!_isInitialized) {
      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.primaryStart.withOpacity(0.1),
                AppColors.primaryEnd.withOpacity(0.05),
              ],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryStart.withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '正在初始化...',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    
    final totalChars = _calculateTotalChars();
    final isMemoryFull = totalChars > 50000; // 用户API支持60K tokens

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 动态背景
          _buildAnimatedBackground(),
          
          // 主内容
          Column(
            children: [
              // 华丽渐变 AppBar
              _buildGlassAppBar(context, totalChars, isMemoryFull),
              
              // 记忆状态栏 - 玻璃效果
              if (totalChars > 0)
                _buildMemoryStatusBar(totalChars, isMemoryFull),
              
              // 推理链/Plan 显示面板
              if (_showReasoningPanel && _sending)
                _buildReasoningPanel(),
              
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
        ],
      ),
    );
  }
  
  /// 动态渐变背景
  Widget _buildAnimatedBackground() {
    return AnimatedBuilder(
      animation: _backgroundAnimation,
      builder: (context, child) {
        final value = _backgroundAnimation.value;
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(
                math.cos(value) * 0.5,
                math.sin(value) * 0.5,
              ),
              end: Alignment(
                math.cos(value + math.pi) * 0.5,
                math.sin(value + math.pi) * 0.5,
              ),
              colors: [
                AppColors.bgStart,
                Color.lerp(AppColors.bgEnd, AppColors.primaryStart.withOpacity(0.05), 
                    (math.sin(value) + 1) / 2)!,
                AppColors.bgEnd,
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
          child: CustomPaint(
            painter: _ParticlePainter(value),
            size: Size.infinite,
          ),
        );
      },
    );
  }
  
  /// 推理链/Plan 显示面板
  Widget _buildReasoningPanel() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primaryStart.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryStart.withOpacity(0.1),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.psychology_rounded, size: 16, color: Colors.white),
              ),
              const SizedBox(width: 10),
              const Text(
                'Agent 推理过程',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              if (_currentPlan != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primaryStart.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Step ${_currentPlanStep + 1}/${_currentPlan!.steps.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryStart,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _showReasoningPanel = false),
                child: Icon(Icons.close_rounded, size: 18, color: Colors.grey[400]),
              ),
            ],
          ),
          
          // Plan 信息
          if (_currentPlan != null) ...[
            const SizedBox(height: 12),
            _buildPlanInfo(_currentPlan!),
          ],
          
          // 推理步骤
          if (_reasoningSteps.isNotEmpty) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _reasoningSteps.asMap().entries.map((entry) {
                    final index = entry.key;
                    final step = entry.value;
                    final isActive = index == _reasoningSteps.length - 1;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: isActive 
                                  ? AppColors.primaryStart 
                                  : Colors.green.withOpacity(0.8),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: isActive
                                  ? SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: const AlwaysStoppedAnimation(Colors.white),
                                      ),
                                    )
                                  : const Icon(Icons.check, size: 12, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              step,
                              style: TextStyle(
                                fontSize: 12,
                                color: isActive ? AppColors.primaryStart : Colors.grey[600],
                                fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
          
          // 当前推理
          if (_currentReasoning.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primaryStart.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBouncingDots(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _currentReasoning,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[700],
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
  
  /// Plan 信息展示
  Widget _buildPlanInfo(AgentPlan plan) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primaryStart.withOpacity(0.08),
            AppColors.primaryEnd.withOpacity(0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primaryStart.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 三轮思考
          _buildThinkingRow('🎯 意图', plan.userIntent),
          const SizedBox(height: 6),
          _buildThinkingRow('🔧 能力', plan.capabilityReview),
          const SizedBox(height: 6),
          _buildThinkingRow('✨ 预期', plan.expectedOutcome),
          const SizedBox(height: 10),
          
          // 执行步骤
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: plan.steps.asMap().entries.map((entry) {
              final index = entry.key;
              final step = entry.value;
              final isCompleted = index < _currentPlanStep;
              final isActive = index == _currentPlanStep;
              
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isCompleted 
                      ? Colors.green.withOpacity(0.15)
                      : isActive 
                          ? AppColors.primaryStart.withOpacity(0.2)
                          : Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isCompleted 
                        ? Colors.green.withOpacity(0.3)
                        : isActive 
                            ? AppColors.primaryStart.withOpacity(0.4)
                            : Colors.grey.withOpacity(0.2),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCompleted)
                      const Icon(Icons.check_circle, size: 14, color: Colors.green)
                    else if (isActive)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(AppColors.primaryStart),
                        ),
                      )
                    else
                      Icon(Icons.circle_outlined, size: 14, color: Colors.grey[400]),
                    const SizedBox(width: 6),
                    Text(
                      '${index + 1}. ${step.action.name}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                        color: isCompleted 
                            ? Colors.green[700]
                            : isActive 
                                ? AppColors.primaryStart
                                : Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
  
  Widget _buildThinkingRow(String label, String content) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            content,
            style: TextStyle(fontSize: 11, color: Colors.grey[700]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // 记忆状态栏
  Widget _buildMemoryStatusBar(int totalChars, bool isMemoryFull) {
    final progress = (totalChars / 50000).clamp(0.0, 1.0); // 用户API支持60K tokens
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
                      // 发送按钮 - 带脉冲动画和点击波纹
                      GestureDetector(
                        onTapDown: (_) {
                          if (!_sending) {
                            _sendButtonController.forward();
                          }
                        },
                        onTapUp: (_) {
                          _sendButtonController.reverse();
                        },
                        onTapCancel: () {
                          _sendButtonController.reverse();
                        },
                        child: AnimatedBuilder(
                          animation: Listenable.merge([_pulseController, _sendButtonController]),
                          builder: (context, child) {
                            final canSend = !_sending && (_inputCtrl.text.trim().isNotEmpty || _selectedImage != null);
                            final pressScale = 1.0 - _sendButtonController.value * 0.1;
                            return Transform.scale(
                              scale: (canSend ? 1.0 + (_pulseAnimation.value - 1.0) * 0.3 : 1.0) * pressScale,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // 外圈光环动效
                                  if (canSend)
                                    ...List.generate(2, (i) {
                                      final delay = i * 0.5;
                                      final ringValue = (_pulseController.value + delay) % 1.0;
                                      return Container(
                                        width: 48 + ringValue * 20,
                                        height: 48 + ringValue * 20,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: AppColors.primaryStart.withOpacity((1 - ringValue) * 0.3),
                                            width: 2,
                                          ),
                                        ),
                                      );
                                    }),
                                  // 主按钮
                                  Container(
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
                                        splashColor: Colors.white.withOpacity(0.3),
                                        highlightColor: Colors.white.withOpacity(0.1),
                                        child: Container(
                                          width: 48,
                                          height: 48,
                                          alignment: Alignment.center,
                                          child: AnimatedSwitcher(
                                            duration: const Duration(milliseconds: 200),
                                            transitionBuilder: (child, animation) {
                                              return RotationTransition(
                                                turns: Tween(begin: 0.5, end: 1.0).animate(animation),
                                                child: ScaleTransition(scale: animation, child: child),
                                              );
                                            },
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
                                ],
                              ),
                            );
                          },
                        ),
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
                // 推理链显示切换按钮
                _buildAppBarButton(
                  icon: _showReasoningPanel ? Icons.psychology : Icons.psychology_outlined,
                  onPressed: () {
                    setState(() => _showReasoningPanel = !_showReasoningPanel);
                  },
                  tooltip: '显示/隐藏推理过程',
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
  /// Enforce tool-first policy: when the model tries to直接回答, force a tool action if patterns are detected.
  AgentDecision _enforceToolPolicy(String userText, AgentDecision decision, {required bool hasKnowledge}) {
    if (decision.type != AgentActionType.answer) return decision;

    final dataRegex = RegExp(r'(数据|统计|趋势|来源|权威|最新|市场|指标|分析)');
    final planRegex = RegExp(r'(计划|步骤|路线图|时间表|里程碑|方案|任务|进度|风险|预算|成本|资源)');
    final visionRegex = RegExp(r'(pdf|扫描|图片|截图|ocr)', caseSensitive: false);

    final needsData = dataRegex.hasMatch(userText);
    final needsPlan = planRegex.hasMatch(userText);
    final needsVision = visionRegex.hasMatch(userText);

    // Vision/OCR trigger
    if (needsVision) {
      return AgentDecision(
        type: AgentActionType.vision,
        content: decision.content ?? '请分析上传的文件/图片（若为PDF请先OCR）并提取关键信息。',
        reason: '${decision.reason ?? ''} [AUTO-TOOL] 检测到PDF/图片/扫描，先用 vision/OCR 获取内容。',
        confidence: decision.confidence ?? 0.6,
        continueAfter: true,
      );
    }

    // Data/plan trigger → search first (prefer knowledge search for规划类)
    if (needsData || needsPlan) {
      final query = _buildQueryFromUser(userText);
      final preferKnowledge = hasKnowledge && needsPlan && !needsData;
      final actionType = preferKnowledge ? AgentActionType.search_knowledge : AgentActionType.search;
      return AgentDecision(
        type: actionType,
        query: query,
        reason: '${decision.reason ?? ''} [AUTO-TOOL] 触发${needsData ? '数据/趋势' : '规划'}场景，先${preferKnowledge ? 'search_knowledge' : 'search'}获取依据。',
        confidence: decision.confidence ?? 0.7,
        continueAfter: true,
      );
    }

    return decision;
  }

  /// Build a concise query from user text (limit length, strip newlines)
  String _buildQueryFromUser(String userText) {
    final normalized = userText.replaceAll('\n', ' ').trim();
    if (normalized.isEmpty) return '查询';
    if (normalized.length <= 80) return normalized;
    return normalized.substring(0, 80);
  }

  /// Start periodic polling for async tasks
  void _startTaskPolling() {
    _taskPollTimer?.cancel();
    _taskPollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _pollAsyncTasks();
    });
  }

  Future<void> _pollAsyncTasks() async {
    if (_taskPollInProgress) return;
    _taskPollInProgress = true;
    try {
      await _taskQueue.pollTasks();
      final ready = _taskQueue.getUndeliveredReady();
      if (ready.isEmpty) return;

      final refs = <ReferenceItem>[];
      final deliveredIds = <String>[];
      final newSystemMessages = <ChatMessage>[];

      for (final task in ready) {
        deliveredIds.add(task.id);
        final isSuccess = task.status == TaskStatus.success;
        final sourceType = _mapTaskTypeToSource(task.type);
        final statusLabel = isSuccess ? '✅ 已完成' : (task.status == TaskStatus.failed ? '❌ 失败' : '⚠️ 异常');
        final snippet = (task.result?.isNotEmpty == true ? task.result! : task.error ?? '未返回结果').trim();
        refs.add(ReferenceItem(
          title: '$statusLabel · 任务 ${task.type}',
          url: task.statusUrl ?? 'task://${task.id}',
          snippet: snippet,
          sourceName: 'AsyncTask',
          sourceType: sourceType,
          reliability: isSuccess ? 0.7 : 0.3,
          authorityLevel: 'unknown',
          caveats: task.error != null ? [task.error!] : null,
        ));

        // Add a system message to inform user/agent
        newSystemMessages.add(ChatMessage(
          'system',
          '$statusLabel: 任务 ${task.id} (${task.type})\n${snippet.isNotEmpty ? snippet : "无内容"}',
          isMemory: true,
        ));
      }

      if (refs.isNotEmpty) {
        await _refManager.addExternalReferences(refs);
        if (mounted) {
          setState(() {
            _messages.addAll(newSystemMessages);
            _saveChatHistory();
          });
        } else {
          _messages.addAll(newSystemMessages);
          _saveChatHistory();
        }
      }

      await _taskQueue.markDelivered(deliveredIds);
    } catch (e) {
      debugPrint('Async task polling error: $e');
    } finally {
      _taskPollInProgress = false;
    }
  }

  String _mapTaskTypeToSource(String type) {
    final lower = type.toLowerCase();
    if (lower.contains('vision') || lower.contains('ocr') || lower.contains('image')) return 'vision';
    if (lower.contains('read') || lower.contains('url')) return 'url_content';
    if (lower.contains('knowledge')) return 'knowledge';
    if (lower.contains('search')) return 'web';
    if (lower.contains('analysis') || lower.contains('summary')) return 'feedback';
    return 'feedback';
  }

  /// Finalize a decision: enforce tool policy, fill missing fields with safe defaults
  AgentDecision _finalizeDecision(String userText, AgentDecision decision, {required bool hasKnowledge}) {
    final enforced = _enforceToolPolicy(userText, decision, hasKnowledge: hasKnowledge);
    
    // Fill required fields per tool
    switch (enforced.type) {
      case AgentActionType.search:
      case AgentActionType.search_knowledge:
        final safeQuery = (enforced.query ?? _buildQueryFromUser(userText)).trim();
        final safeReason = enforced.reason?.isNotEmpty == true ? enforced.reason! : '[AUTO-FIX] 填充默认原因';
        return enforced.copyWith(
          query: safeQuery.isEmpty ? _buildQueryFromUser(userText) : safeQuery,
          reason: safeReason,
          confidence: enforced.confidence ?? 0.7,
          continueAfter: true,
        );
      case AgentActionType.vision:
        final safeContent = enforced.content?.isNotEmpty == true
            ? enforced.content!
            : '请分析上传的文件/图片（若为PDF请先OCR）并提取关键信息。';
        return enforced.copyWith(
          content: safeContent,
          reason: enforced.reason ?? '[AUTO-FIX] 填充默认原因',
          confidence: enforced.confidence ?? 0.6,
          continueAfter: true,
        );
      case AgentActionType.draw:
        final safePrompt = enforced.content?.isNotEmpty == true ? enforced.content! : 'user requested image';
        return enforced.copyWith(
          content: safePrompt,
          reason: enforced.reason ?? '[AUTO-FIX] 填充默认原因',
          confidence: enforced.confidence ?? 0.8,
          continueAfter: false,
        );
      case AgentActionType.read_url:
        final safeQuery = enforced.query?.isNotEmpty == true ? enforced.query! : _buildQueryFromUser(userText);
        return enforced.copyWith(
          query: safeQuery,
          reason: enforced.reason ?? '[AUTO-FIX] 填充默认原因',
          confidence: enforced.confidence ?? 0.7,
          continueAfter: true,
        );
      case AgentActionType.save_file:
        final safeName = enforced.filename?.isNotEmpty == true ? enforced.filename! : 'output_${DateTime.now().millisecondsSinceEpoch}.md';
        final safeContent = enforced.content?.isNotEmpty == true ? enforced.content! : '# 输出内容\n';
        return enforced.copyWith(
          filename: safeName,
          content: safeContent,
          reason: enforced.reason ?? '[AUTO-FIX] 填充默认原因',
          confidence: enforced.confidence ?? 0.8,
          continueAfter: false,
        );
      case AgentActionType.take_note:
        final safeNote = enforced.content?.isNotEmpty == true ? enforced.content! : '待记录要点';
        return enforced.copyWith(
          content: safeNote,
          reason: enforced.reason ?? '[AUTO-FIX] 填充默认原因',
          confidence: enforced.confidence ?? 0.8,
          continueAfter: true,
        );
      default:
        return enforced.copyWith(
          reason: enforced.reason ?? '[AUTO-FIX] 填充默认原因',
          confidence: enforced.confidence ?? 0.7,
        );
    }
  }
}

/// 粒子背景画笔 - 优雅的流动粒子效果
class _ParticlePainter extends CustomPainter {
  final double animationValue;
  
  _ParticlePainter(this.animationValue);
  
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill;
    
    // 绘制多个流动的粒子/光点
    for (int i = 0; i < 15; i++) {
      final seed = i * 137.5; // 黄金角度间隔
      final x = (math.sin(animationValue + seed) * 0.4 + 0.5) * size.width;
      final y = (math.cos(animationValue * 0.7 + seed) * 0.4 + 0.5) * size.height;
      final radius = 2 + math.sin(animationValue * 2 + seed) * 1.5;
      final opacity = 0.1 + math.sin(animationValue + seed) * 0.05;
      
      paint.color = AppColors.primaryStart.withOpacity(opacity.clamp(0.02, 0.15));
      canvas.drawCircle(Offset(x, y), radius, paint);
      
      // 光晕效果
      paint.color = AppColors.primaryStart.withOpacity(opacity * 0.3);
      canvas.drawCircle(Offset(x, y), radius * 2.5, paint);
    }
    
    // 绘制几条优雅的流动曲线
    for (int i = 0; i < 3; i++) {
      final path = Path();
      final startY = size.height * (0.3 + i * 0.2);
      
      path.moveTo(0, startY);
      for (double x = 0; x <= size.width; x += 10) {
        final wave = math.sin(x * 0.01 + animationValue + i) * 30;
        path.lineTo(x, startY + wave);
      }
      
      paint
        ..color = AppColors.primaryStart.withOpacity(0.03)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      
      canvas.drawPath(path, paint);
    }
  }
  
  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}
