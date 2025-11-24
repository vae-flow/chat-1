import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

void main() {
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

  ChatMessage(this.role, this.content, {this.imageUrl, this.localImagePath});

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'imageUrl': imageUrl,
        'localImagePath': localImagePath,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      json['role'],
      json['content'],
      imageUrl: json['imageUrl'],
      localImagePath: json['localImagePath'],
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
  
  bool _sending = false;
  final List<ChatMessage> _messages = [];
  XFile? _selectedImage;

  // Settings
  // Chat
  String _chatBase = 'https://your-oneapi-host/v1';
  String _chatKey = '';
  String _chatModel = 'gpt-3.5-turbo';
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

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadChatHistory();
  }

  Future<void> _loadChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? history = prefs.getStringList('chat_history');
    if (history != null) {
      setState(() {
        _messages.clear();
        _messages.addAll(history.map((e) => ChatMessage.fromJson(json.decode(e))));
      });
      // Scroll to bottom after loading
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _saveChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = _messages.map((m) => json.encode(m.toJson())).toList();
    await prefs.setStringList('chat_history', history);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _chatBase = prefs.getString('chat_base') ?? 'https://your-oneapi-host/v1';
      _chatKey = prefs.getString('chat_key') ?? '';
      _chatModel = prefs.getString('chat_model') ?? 'gpt-3.5-turbo';

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

  Future<void> _performImageGeneration(String prompt) async {
    if (_imgBase.contains('your-oneapi-host') || _imgKey.isEmpty) {
      _showError('请先配置生图 API');
      _openSettings();
      return;
    }

    setState(() {
      _sending = true;
      _messages.add(ChatMessage('user', '🎨 生图指令: $prompt'));
      _saveChatHistory();
    });
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
      setState(() => _sending = false);
    }
  }

  Future<void> _performChatRequest(String content, {String? localImage}) async {
    final isVision = localImage != null;
    final apiBase = isVision ? _visionBase : _chatBase;
    final apiKey = isVision ? _visionKey : _chatKey;
    final model = isVision ? _visionModel : _chatModel;

    if (apiBase.contains('your-oneapi-host') || apiKey.isEmpty) {
      _showError('请先配置 ${isVision ? "识图" : "聊天"} API');
      _openSettings();
      return;
    }

    setState(() {
      _sending = true;
      // Only add user message if it wasn't added by the router logic already
      // But here we assume the caller handles UI message addition if needed.
      // Actually, let's make this function purely about the API call and response handling.
      // We will assume the User message is already added to _messages list by the caller.
    });
    _scrollToBottom();

    try {
      final uri = Uri.parse('${apiBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      
      Object messagesPayload;
      
      if (localImage != null) {
        final bytes = await File(localImage).readAsBytes();
        final base64Image = base64Encode(bytes);
        
        messagesPayload = [
          ..._messages.where((m) => m.localImagePath == null && m.imageUrl == null).map((m) => {'role': m.role, 'content': m.content}),
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
        messagesPayload = _messages.map((m) => {'role': m.role, 'content': m.content}).toList();
      }

      final body = json.encode({
        'model': model,
        'messages': messagesPayload,
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
        final decodedBody = utf8.decode(resp.bodyBytes);
        final data = json.decode(decodedBody);
        final reply = data['choices'][0]['message']['content'] ?? '';
        setState(() {
          _messages.add(ChatMessage('assistant', reply.toString()));
          _saveChatHistory();
        });
        _scrollToBottom();
      } else {
        _showError('发送失败：${resp.statusCode} ${resp.reasonPhrase}');
      }
    } catch (e) {
      _showError('发送异常：$e');
    } finally {
      setState(() => _sending = false);
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
    
    // Take last 6 messages for context
    final recentContext = contextMsgs.length > 6 
        ? contextMsgs.sublist(contextMsgs.length - 6) 
        : contextMsgs;

    final contextBuffer = StringBuffer();
    for (var m in recentContext) {
      if (m.content.isNotEmpty) {
         contextBuffer.writeln('${m.role}: ${m.content}');
      }
    }
    final contextString = contextBuffer.toString().trim();

    final routerUserContent = '''
上下文记忆：
${contextString.isEmpty ? "无" : contextString}

用户刚刚的表达是：
$text
''';

    try {
      final uri = Uri.parse('${effectiveBase.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      
      final systemPrompt = '''
You are an intelligent intent classifier. Analyze the user's input considering the context.
Determine if the user wants to generate/draw/create an image.
Return a JSON object with exactly two keys:
1. "image_prompt": If the user wants an image, provide the optimized English prompt here. If not, set to null.
2. "chat_text": If the user also wants to chat or asks a question (excluding the image generation part), provide that text here. If the user ONLY wants an image, set this to null. If the user ONLY wants to chat, provide the original text here.

Example 1: "Draw a cat" -> {"image_prompt": "A cute cat", "chat_text": null}
Example 2: "Hello, how are you?" -> {"image_prompt": null, "chat_text": "Hello, how are you?"}
Example 3: "Draw it" (Context: User talking about a dragon) -> {"image_prompt": "A dragon", "chat_text": null}

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
    if (imagePrompt != null) {
      // We need to reset _sending because _performImageGeneration sets it too
      setState(() => _sending = false); 
      await _performImageGeneration(imagePrompt);
    }

    if (chatText != null) {
      // If we also generated an image, we might want to wait or run in parallel.
      // For simplicity, run sequentially.
      // IMPORTANT: Do NOT reset _sending to false here if we just finished image generation,
      // because _performChatRequest will set it to true again.
      // Actually, _performChatRequest sets _sending=true at the start.
      // But we need to make sure the UI doesn't flicker or get stuck.
      
      // If we just did image generation, let's add a small delay or just proceed.
      // The issue might be that _performImageGeneration sets _sending=false in finally block.
      // So we are good to start a new request.
      
      await _performChatRequest(chatText);
    } else if (imagePrompt == null) {
      // Fallback if both are null (shouldn't happen with fallback logic)
      setState(() => _sending = false);
    } else {
      // Case: imagePrompt != null BUT chatText == null (User ONLY wanted an image)
      // We must ensure _sending is set to false if it wasn't already handled by _performImageGeneration's finally block
      // (It is handled there, so we are good).
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
  }

  @override
  Widget build(BuildContext context) {
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
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
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
                      tooltip: '强制生图 (DALL-E)',
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

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _chatBaseCtrl.dispose();
    _chatKeyCtrl.dispose();
    _chatModelCtrl.dispose();
    _imgBaseCtrl.dispose();
    _imgKeyCtrl.dispose();
    _imgModelCtrl.dispose();
    _visionBaseCtrl.dispose();
    _visionKeyCtrl.dispose();
    _visionModelCtrl.dispose();
    _routerBaseCtrl.dispose();
    _routerKeyCtrl.dispose();
    _routerModelCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _chatBaseCtrl.text = prefs.getString('chat_base') ?? 'https://your-oneapi-host/v1';
      _chatKeyCtrl.text = prefs.getString('chat_key') ?? '';
      _chatModelCtrl.text = prefs.getString('chat_model') ?? 'gpt-3.5-turbo';

      _imgBaseCtrl.text = prefs.getString('img_base') ?? 'https://your-oneapi-host/v1';
      _imgKeyCtrl.text = prefs.getString('img_key') ?? '';
      _imgModelCtrl.text = prefs.getString('img_model') ?? 'dall-e-3';

      _visionBaseCtrl.text = prefs.getString('vision_base') ?? 'https://your-oneapi-host/v1';
      _visionKeyCtrl.text = prefs.getString('vision_key') ?? '';
      _visionModelCtrl.text = prefs.getString('vision_model') ?? 'gpt-4-vision-preview';

      _routerBaseCtrl.text = prefs.getString('router_base') ?? 'https://your-oneapi-host/v1';
      _routerKeyCtrl.text = prefs.getString('router_key') ?? '';
      _routerModelCtrl.text = prefs.getString('router_model') ?? 'gpt-3.5-turbo';
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    
    await prefs.setString('chat_base', _chatBaseCtrl.text.trim());
    await prefs.setString('chat_key', _chatKeyCtrl.text.trim());
    await prefs.setString('chat_model', _chatModelCtrl.text.trim());

    await prefs.setString('img_base', _imgBaseCtrl.text.trim());
    await prefs.setString('img_key', _imgKeyCtrl.text.trim());
    await prefs.setString('img_model', _imgModelCtrl.text.trim());

    await prefs.setString('vision_base', _visionBaseCtrl.text.trim());
    await prefs.setString('vision_key', _visionKeyCtrl.text.trim());
    await prefs.setString('vision_model', _visionModelCtrl.text.trim());

    await prefs.setString('router_base', _routerBaseCtrl.text.trim());
    await prefs.setString('router_key', _routerKeyCtrl.text.trim());
    await prefs.setString('router_model', _routerModelCtrl.text.trim());

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

  Widget _buildConfigTab(String label, TextEditingController base, TextEditingController key, TextEditingController model) {
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
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildConfigTab('聊天', _chatBaseCtrl, _chatKeyCtrl, _chatModelCtrl),
          _buildConfigTab('生图', _imgBaseCtrl, _imgKeyCtrl, _imgModelCtrl),
          _buildConfigTab('识图', _visionBaseCtrl, _visionKeyCtrl, _visionModelCtrl),
          _buildConfigTab('分流 (Router)', _routerBaseCtrl, _routerKeyCtrl, _routerModelCtrl),
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
