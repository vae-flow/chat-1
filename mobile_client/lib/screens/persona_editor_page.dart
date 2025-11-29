import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/persona.dart';
import '../services/image_service.dart';

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
      final localPath = await downloadAndSaveImage(imageUrl, StorageType.avatar);
      
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
