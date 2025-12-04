import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  final Future<void> Function()? onDeepProfile;

  const SettingsPage({super.key, this.onDeepProfile});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isFabExpanded = false;
  
  // Chat
  final _chatBaseCtrl = TextEditingController();
  final _chatKeyCtrl = TextEditingController();
  final _chatModelCtrl = TextEditingController();
  final _summaryModelCtrl = TextEditingController(); // New Controller
  bool _enableStream = true;
  
  // Image
  final _imgBaseCtrl = TextEditingController();
  final _imgKeyCtrl = TextEditingController();
  final _imgModelCtrl = TextEditingController();
  bool _useChatApiForImage = false; // New: Toggle for Chat API Image Generation

  // Vision
  final _visionBaseCtrl = TextEditingController();
  final _visionKeyCtrl = TextEditingController();
  final _visionModelCtrl = TextEditingController();
  // OCR (Dedicated, do not reuse Vision/Chat)
  final _ocrBaseCtrl = TextEditingController();
  final _ocrKeyCtrl = TextEditingController();
  final _ocrModelCtrl = TextEditingController();

  // Router
  final _routerBaseCtrl = TextEditingController();
  final _routerKeyCtrl = TextEditingController();
  final _routerModelCtrl = TextEditingController();

  // Profiler
  final _profileBaseCtrl = TextEditingController();
  final _profileKeyCtrl = TextEditingController();
  final _profileModelCtrl = TextEditingController();

  // Search
  final _exaBaseCtrl = TextEditingController();
  final _exaKeyCtrl = TextEditingController();
  final _youBaseCtrl = TextEditingController();
  final _youKeyCtrl = TextEditingController();
  final _braveBaseCtrl = TextEditingController();
  final _braveKeyCtrl = TextEditingController();
  String _searchProvider = 'mock';
  bool _enableSearchSynthesis = true;  // Worker综合分析开关

  // Worker Pro (思考型内部处理)
  final _workerProBaseCtrl = TextEditingController();
  final _workerProKeysCtrl = TextEditingController();  // 逗号分隔多密钥
  final _workerProModelCtrl = TextEditingController();

  // Worker (执行型内部处理)
  final _workerBaseCtrl = TextEditingController();
  final _workerKeysCtrl = TextEditingController();  // 逗号分隔多密钥
  final _workerModelCtrl = TextEditingController();

  // Global Memory Editor
  final _globalMemoryCtrl = TextEditingController();
  String _initialGlobalMemory = '';

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 8, vsync: this); // 增加 OCR 标签
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
    _ocrBaseCtrl.dispose();
    _ocrKeyCtrl.dispose();
    _ocrModelCtrl.dispose();
    _routerBaseCtrl.dispose();
    _routerKeyCtrl.dispose();
    _routerModelCtrl.dispose();
    _profileBaseCtrl.dispose();
    _profileKeyCtrl.dispose();
    _profileModelCtrl.dispose();
    _exaBaseCtrl.dispose();
    _exaKeyCtrl.dispose();
    _youBaseCtrl.dispose();
    _youKeyCtrl.dispose();
    _braveBaseCtrl.dispose();
    _braveKeyCtrl.dispose();
    _workerProBaseCtrl.dispose();
    _workerProKeysCtrl.dispose();
    _workerProModelCtrl.dispose();
    _workerBaseCtrl.dispose();
    _workerKeysCtrl.dispose();
    _workerModelCtrl.dispose();
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
      _enableStream = prefs.getBool('enable_stream') ?? true;

      _imgBaseCtrl.text = prefs.getString('img_base') ?? 'https://your-oneapi-host/v1';
      _imgKeyCtrl.text = prefs.getString('img_key') ?? '';
      _imgModelCtrl.text = prefs.getString('img_model') ?? 'dall-e-3';
      _useChatApiForImage = prefs.getBool('use_chat_api_for_image') ?? false;

      _visionBaseCtrl.text = prefs.getString('vision_base') ?? 'https://your-oneapi-host/v1';
      _visionKeyCtrl.text = prefs.getString('vision_key') ?? '';
      _visionModelCtrl.text = prefs.getString('vision_model') ?? 'gpt-4-vision-preview';
      _ocrBaseCtrl.text = prefs.getString('ocr_base') ?? '';
      _ocrKeyCtrl.text = prefs.getString('ocr_key') ?? '';
      _ocrModelCtrl.text = prefs.getString('ocr_model') ?? 'gpt-4o-mini';

      _routerBaseCtrl.text = prefs.getString('router_base') ?? 'https://your-oneapi-host/v1';
      _routerKeyCtrl.text = prefs.getString('router_key') ?? '';
      _routerModelCtrl.text = prefs.getString('router_model') ?? 'gpt-3.5-turbo';

      _profileBaseCtrl.text = prefs.getString('profile_base') ?? 'https://your-oneapi-host/v1';
      _profileKeyCtrl.text = prefs.getString('profile_key') ?? '';
      _profileModelCtrl.text = prefs.getString('profile_model') ?? 'gpt-3.5-turbo';
      
      _exaBaseCtrl.text = prefs.getString('exa_base') ?? 'https://api.exa.ai';
      _exaKeyCtrl.text = prefs.getString('exa_key') ?? '';
      _youBaseCtrl.text = prefs.getString('you_base') ?? 'https://api.ydc-index.io';
      _youKeyCtrl.text = prefs.getString('you_key') ?? '';
      _braveBaseCtrl.text = prefs.getString('brave_base') ?? 'https://api.search.brave.com';
      _braveKeyCtrl.text = prefs.getString('brave_key') ?? '';
      _searchProvider = prefs.getString('search_provider') ?? 'auto';
      _enableSearchSynthesis = prefs.getBool('enable_search_synthesis') ?? true;

      // Worker Pro (思考型)
      _workerProBaseCtrl.text = prefs.getString('worker_pro_base') ?? '';
      _workerProKeysCtrl.text = prefs.getString('worker_pro_keys') ?? '';
      _workerProModelCtrl.text = prefs.getString('worker_pro_model') ?? 'gpt-4o-mini';

      // Worker (执行型)
      _workerBaseCtrl.text = prefs.getString('worker_base') ?? '';
      _workerKeysCtrl.text = prefs.getString('worker_keys') ?? '';
      _workerModelCtrl.text = prefs.getString('worker_model') ?? 'gemini-2.0-flash';

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
    await prefs.setBool('enable_stream', _enableStream);

    await prefs.setString('img_base', _imgBaseCtrl.text.trim());
    await prefs.setString('img_key', _imgKeyCtrl.text.trim());
    await prefs.setString('img_model', _imgModelCtrl.text.trim());
    await prefs.setBool('use_chat_api_for_image', _useChatApiForImage);

    await prefs.setString('vision_base', _visionBaseCtrl.text.trim());
    await prefs.setString('vision_key', _visionKeyCtrl.text.trim());
    await prefs.setString('vision_model', _visionModelCtrl.text.trim());
    await prefs.setString('ocr_base', _ocrBaseCtrl.text.trim());
    await prefs.setString('ocr_key', _ocrKeyCtrl.text.trim());
    await prefs.setString('ocr_model', _ocrModelCtrl.text.trim());

    await prefs.setString('router_base', _routerBaseCtrl.text.trim());
    await prefs.setString('router_key', _routerKeyCtrl.text.trim());
    await prefs.setString('router_model', _routerModelCtrl.text.trim());

    await prefs.setString('profile_base', _profileBaseCtrl.text.trim());
    await prefs.setString('profile_key', _profileKeyCtrl.text.trim());
    await prefs.setString('profile_model', _profileModelCtrl.text.trim());

    await prefs.setString('exa_base', _exaBaseCtrl.text.trim());
    await prefs.setString('exa_key', _exaKeyCtrl.text.trim());
    await prefs.setString('you_base', _youBaseCtrl.text.trim());
    await prefs.setString('you_key', _youKeyCtrl.text.trim());
    await prefs.setString('brave_base', _braveBaseCtrl.text.trim());
    await prefs.setString('brave_key', _braveKeyCtrl.text.trim());
    await prefs.setString('search_provider', _searchProvider);
    await prefs.setBool('enable_search_synthesis', _enableSearchSynthesis);

    // Worker Pro (思考型)
    await prefs.setString('worker_pro_base', _workerProBaseCtrl.text.trim());
    await prefs.setString('worker_pro_keys', _workerProKeysCtrl.text.trim());
    await prefs.setString('worker_pro_model', _workerProModelCtrl.text.trim());

    // Worker (执行型)
    await prefs.setString('worker_base', _workerBaseCtrl.text.trim());
    await prefs.setString('worker_keys', _workerKeysCtrl.text.trim());
    await prefs.setString('worker_model', _workerModelCtrl.text.trim());

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
      final uri = Uri.parse('${baseCtrl.text.replaceAll(RegExp(r"/+$"), "")}/models');
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
        if (!isImageTab && summaryModel != null) ...[
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('启用流式响应 (Streaming)'),
            subtitle: const Text('开启后，回复将逐字显示，体验更流畅。'),
            value: _enableStream,
            onChanged: (val) => setState(() => _enableStream = val),
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
        const Text(
          '配置搜索服务的 API Key。支持多密钥轮换（逗号分隔）。\n'
          '如果选择"自动选择"，系统将按顺序使用已配置的服务 (Exa > You > Brave)。', 
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
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
        const SizedBox(height: 16),
        
        SwitchListTile(
          title: const Text('启用搜索结果综合分析'),
          subtitle: const Text('使用 Worker API 对搜索结果进行全局视角综合，提取共识、分歧和盲区'),
          value: _enableSearchSynthesis,
          onChanged: (v) => setState(() => _enableSearchSynthesis = v),
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 24),

        const Text('Exa.ai Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _exaBaseCtrl,
          decoration: const InputDecoration(
            labelText: 'Exa API Base',
            border: OutlineInputBorder(),
            hintText: 'https://api.exa.ai',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _exaKeyCtrl,
          decoration: const InputDecoration(
            labelText: 'Exa API Keys（逗号分隔多个）',
            border: OutlineInputBorder(),
            helperText: '多密钥自动轮换',
          ),
          maxLines: 2,
        ),
        const SizedBox(height: 16),

        const Text('You.com Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _youBaseCtrl,
          decoration: const InputDecoration(
            labelText: 'You.com API Base',
            border: OutlineInputBorder(),
            hintText: 'https://ydc-index.io/v1',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _youKeyCtrl,
          decoration: const InputDecoration(
            labelText: 'You.com API Keys（逗号分隔多个）',
            border: OutlineInputBorder(),
            helperText: '多密钥自动轮换',
          ),
          maxLines: 2,
        ),
        const SizedBox(height: 16),

        const Text('Brave Search Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _braveBaseCtrl,
          decoration: const InputDecoration(
            labelText: 'Brave API Base',
            border: OutlineInputBorder(),
            hintText: 'https://api.search.brave.com',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _braveKeyCtrl,
          decoration: const InputDecoration(
            labelText: 'Brave API Keys（逗号分隔多个）',
            border: OutlineInputBorder(),
            helperText: '多密钥自动轮换',
          ),
          maxLines: 2,
        ),
      ],
    );
  }

  Widget _buildMemoryTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('用户画像档案 (User Profile)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          '这是系统根据对话自动生成的“用户侧写”。它包含了您的性格、偏好、价值观等深度信息，用于让 AI 更懂您。',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _globalMemoryCtrl,
          maxLines: 20,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '暂无画像...',
          ),
        ),
        const SizedBox(height: 24),
        const Text('深度刻画 (Deep Profiling)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          '配置专用的刻画 API，手动触发一次全量历史记录的深度分析。这可能需要较长时间。',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _profileBaseCtrl,
          decoration: const InputDecoration(
            labelText: 'Profiler API Base',
            hintText: 'https://api.openai.com/v1',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _profileKeyCtrl,
          decoration: const InputDecoration(
            labelText: 'Profiler API Key',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _profileModelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Profiler Model',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _loading ? null : () => _fetchModels(_profileBaseCtrl, _profileKeyCtrl, _profileModelCtrl),
              icon: _loading 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_download),
              tooltip: '获取模型',
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (widget.onDeepProfile != null)
          Center(
            child: ElevatedButton.icon(
              onPressed: () async {
                // Capture the callback BEFORE any navigation
                final deepProfileCallback = widget.onDeepProfile;
                if (deepProfileCallback == null) return;
                
                // Save settings first to ensure keys are available
                await _save();
                
                // CRITICAL FIX: Call the callback BEFORE closing the page
                // This ensures the ChatPage context is valid when showDialog is called
                // The dialog will appear on top of SettingsPage, then we close SettingsPage
                try {
                  // Start profiling immediately (it will show its own dialog)
                  // Use unawaited call so dialog shows immediately
                  deepProfileCallback();
                  
                  // Wait a bit for the dialog to be created and shown
                  await Future.delayed(const Duration(milliseconds: 200));
                  
                  // Close settings page AFTER profiling dialog is visible
                  if (mounted) {
                    Navigator.pop(context);
                  }
                } catch (e) {
                  debugPrint('onDeepProfile callback error: $e');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('深度刻画启动失败: $e')),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
              icon: const Icon(Icons.psychology),
              label: const Text('开始深度刻画 (Start Deep Profiling)'),
            ),
          ),
      ],
    );
  }

  Widget _buildWorkerTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('⚙️ 内部处理 API', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'Worker API 用于内部任务处理（压缩、翻译、意图识别等），不影响聊天功能。\n'
          '如果不配置，将自动 fallback 到聊天 API。\n'
          '多密钥用逗号分隔，系统会自动轮换以避免 RPM 限制。',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 24),
        
        // Worker Pro Section
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.withOpacity(0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.psychology, color: Colors.blue),
                  SizedBox(width: 8),
                  Text('Worker Pro（思考型）', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '用于需要理解和判断的任务：意图识别、总结压缩、搜索词改写、摘要生成。\n'
                '推荐：gpt-4o-mini / claude-haiku / gemini-1.5-flash',
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _workerProBaseCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Base URL',
                  hintText: 'https://api.openai.com/v1',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _workerProKeysCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Keys（逗号分隔多个）',
                  hintText: 'sk-key1, sk-key2, sk-key3',
                  border: OutlineInputBorder(),
                  isDense: true,
                  helperText: '多密钥自动轮换，防止 RPM 限制',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _workerProModelCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Model',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _loading ? null : () {
                      final keys = _workerProKeysCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                      if (keys.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先填写 API Key')));
                        return;
                      }
                      // 用第一个 key 获取模型列表
                      final tempKeyCtrl = TextEditingController(text: keys.first);
                      _fetchModels(_workerProBaseCtrl, tempKeyCtrl, _workerProModelCtrl);
                    },
                    icon: const Icon(Icons.cloud_download, size: 20),
                    tooltip: '获取模型列表',
                  ),
                ],
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 24),
        
        // Worker Section
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.withOpacity(0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.bolt, color: Colors.green),
                  SizedBox(width: 8),
                  Text('Worker（执行型）', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '用于简单机械任务：翻译、格式校验、关键词提取、去重判断。\n'
                '推荐：gemini-2.0-flash / gpt-3.5-turbo（最便宜最快）',
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _workerBaseCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Base URL',
                  hintText: 'https://api.openai.com/v1',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _workerKeysCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Keys（逗号分隔多个）',
                  hintText: 'sk-key1, sk-key2, sk-key3',
                  border: OutlineInputBorder(),
                  isDense: true,
                  helperText: '多密钥自动轮换，可并行调用',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _workerModelCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Model',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _loading ? null : () {
                      final keys = _workerKeysCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                      if (keys.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先填写 API Key')));
                        return;
                      }
                      final tempKeyCtrl = TextEditingController(text: keys.first);
                      _fetchModels(_workerBaseCtrl, tempKeyCtrl, _workerModelCtrl);
                    },
                    icon: const Icon(Icons.cloud_download, size: 20),
                    tooltip: '获取模型列表',
                  ),
                ],
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 24),
        
        // Fallback 说明
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline, color: Colors.orange, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Fallback 策略：Worker 未配置 → Worker Pro → 分流 API → 聊天 API',
                  style: TextStyle(fontSize: 11, color: Colors.orange),
                ),
              ),
            ],
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
            Tab(text: 'OCR', icon: Icon(Icons.document_scanner)),
            Tab(text: '分流', icon: Icon(Icons.alt_route)),
            Tab(text: '搜索', icon: Icon(Icons.search)),
            Tab(text: 'Worker', icon: Icon(Icons.settings_suggest)),
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
          _buildConfigTab('OCR (扫描件专用)', _ocrBaseCtrl, _ocrKeyCtrl, _ocrModelCtrl),
          _buildConfigTab('分流 (Router)', _routerBaseCtrl, _routerKeyCtrl, _routerModelCtrl),
          _buildSearchTab(),
          _buildWorkerTab(),
          _buildMemoryTab(),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_isFabExpanded) ...[
            FloatingActionButton.extended(
              heroTag: 'export',
              onPressed: () {
                _exportSettings();
                setState(() => _isFabExpanded = false);
              },
              icon: const Icon(Icons.copy),
              label: const Text('导出配置'),
              backgroundColor: Colors.orange,
            ),
            const SizedBox(height: 16),
            FloatingActionButton.extended(
              heroTag: 'import',
              onPressed: () {
                _importSettings();
                setState(() => _isFabExpanded = false);
              },
              icon: const Icon(Icons.paste),
              label: const Text('导入配置'),
              backgroundColor: Colors.teal,
            ),
            const SizedBox(height: 16),
            FloatingActionButton.extended(
              heroTag: 'save',
              onPressed: () {
                _save();
                setState(() => _isFabExpanded = false);
              },
              icon: const Icon(Icons.save),
              label: const Text('保存所有设置'),
            ),
            const SizedBox(height: 16),
          ],
          FloatingActionButton(
            heroTag: 'menu',
            onPressed: () => setState(() => _isFabExpanded = !_isFabExpanded),
            child: Icon(_isFabExpanded ? Icons.close : Icons.menu),
          ),
        ],
      ),
    );
  }

  Future<void> _exportSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final allData = <String, dynamic>{};
    final keys = prefs.getKeys();
    for (var key in keys) {
      final val = prefs.get(key);
      allData[key] = val;
    }
    final jsonStr = json.encode(allData);
    await Clipboard.setData(ClipboardData(text: jsonStr));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已复制到剪贴板 (包含 Key，请勿随意分享)')),
      );
    }
  }

  Future<void> _importSettings() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板为空')),
        );
      }
      return;
    }
    
    try {
      final jsonMap = json.decode(data!.text!);
      final prefs = await SharedPreferences.getInstance();
      for (var entry in jsonMap.entries) {
        if (entry.value is String) {
          await prefs.setString(entry.key, entry.value);
        } else if (entry.value is bool) {
          await prefs.setBool(entry.key, entry.value);
        } else if (entry.value is int) {
          await prefs.setInt(entry.key, entry.value);
        } else if (entry.value is double) {
          await prefs.setDouble(entry.key, entry.value);
        } else if (entry.value is List) {
           await prefs.setStringList(entry.key, List<String>.from(entry.value));
        }
      }
      await _load(); // Reload UI
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('配置导入成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: 格式错误 $e')),
        );
      }
    }
  }
}
