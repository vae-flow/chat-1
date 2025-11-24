import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'One-API Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const ChatPage(),
    );
  }
}

class ChatMessage {
  final String role;
  final String content;
  ChatMessage(this.role, this.content);
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _baseCtrl =
      TextEditingController(text: 'https://your-oneapi-host/v1');
  final TextEditingController _keyCtrl =
      TextEditingController(text: 'sk-your-oneapi-token');
  final TextEditingController _modelCtrl =
      TextEditingController(text: 'gpt-4o-mini');
  final TextEditingController _inputCtrl = TextEditingController();
  bool _loadingModels = false;
  bool _sending = false;
  List<String> _models = [];
  final List<ChatMessage> _messages = [];

  @override
  void dispose() {
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchModels() async {
    setState(() => _loadingModels = true);
    try {
      final uri = Uri.parse('${_baseCtrl.text.replaceAll(RegExp(r"/\$"), "")}/models');
      final resp = await http.get(uri, headers: {
        'Authorization': 'Bearer ${_keyCtrl.text}',
      });
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final List items = data['data'] ?? [];
        final fetched = items
            .map((e) => e['id']?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toList();
        setState(() {
          _models = fetched;
          if (fetched.isNotEmpty) {
            _modelCtrl.text = fetched.first;
          }
        });
      } else {
        _showError('拉取模型失败：${resp.statusCode} ${resp.reasonPhrase}');
      }
    } catch (e) {
      _showError('拉取模型异常：$e');
    } finally {
      setState(() => _loadingModels = false);
    }
  }

  Future<void> _send() async {
    final content = _inputCtrl.text.trim();
    if (content.isEmpty) return;
    setState(() {
      _sending = true;
      _messages.add(ChatMessage('user', content));
      _inputCtrl.clear();
    });
    try {
      final uri =
          Uri.parse('${_baseCtrl.text.replaceAll(RegExp(r"/\$"), "")}/chat/completions');
      final body = json.encode({
        'model': _modelCtrl.text.trim(),
        'messages': _buildOpenAiMessages(),
        'stream': false,
      });
      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${_keyCtrl.text}',
          'Content-Type': 'application/json',
        },
        body: body,
      );
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final reply = data['choices'][0]['message']['content'] ?? '';
        setState(() {
          _messages.add(ChatMessage('assistant', reply.toString()));
          if (_messages.length > 20) {
            _messages.removeRange(0, _messages.length - 20);
          }
        });
      } else {
        _showError('发送失败：${resp.statusCode} ${resp.reasonPhrase}');
      }
    } catch (e) {
      _showError('发送异常：$e');
    } finally {
      setState(() => _sending = false);
    }
  }

  List<Map<String, String>> _buildOpenAiMessages() {
    final List<Map<String, String>> msgs = [];
    for (final m in _messages) {
      msgs.add({'role': m.role, 'content': m.content});
    }
    return msgs;
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('One-API 客户端'),
        actions: [
          IconButton(
            onPressed: _loadingModels ? null : _fetchModels,
            icon: _loadingModels
                ? const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: '拉取模型',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            TextField(
              controller: _baseCtrl,
              decoration: const InputDecoration(labelText: 'API Base (含 /v1)'),
            ),
            TextField(
              controller: _keyCtrl,
              decoration: const InputDecoration(labelText: 'API Key'),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _models.contains(_modelCtrl.text) ? _modelCtrl.text : null,
                    items: _models
                        .map(
                          (m) => DropdownMenuItem(
                            value: m,
                            child: Text(m, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _modelCtrl.text = val);
                      }
                    },
                    decoration: const InputDecoration(labelText: '选择模型（可手填）'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _modelCtrl,
                    decoration: const InputDecoration(labelText: '模型/别名'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final m = _messages[index];
                  final isUser = m.role == 'user';
                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    alignment:
                        isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isUser ? Colors.teal.shade100 : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(m.content),
                    ),
                  );
                },
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '输入消息',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _sending ? null : _send,
                  child: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('发送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
