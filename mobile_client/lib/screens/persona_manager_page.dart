import 'dart:io';
import 'package:flutter/material.dart';
import '../models/persona.dart';
import 'persona_editor_page.dart';

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
