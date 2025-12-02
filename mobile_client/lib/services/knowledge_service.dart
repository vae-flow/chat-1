import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/knowledge.dart';

class KnowledgeService {
  static final KnowledgeService _instance = KnowledgeService._internal();
  factory KnowledgeService() => _instance;
  KnowledgeService._internal();

  List<KnowledgeFile> _files = [];
  String _currentPersonaId = '';
  bool _initialized = false;

  Future<void> init() async {
    // Just mark as ready, actual loading happens when persona is set
    _initialized = true;
  }

  /// Switch to a different persona's knowledge base
  Future<void> setPersona(String personaId) async {
    if (_currentPersonaId == personaId && _files.isNotEmpty) return;
    _currentPersonaId = personaId;
    await _load();
  }

  /// Force reload current persona's knowledge base (for sync after external changes)
  Future<void> reload() async {
    await _load();
  }

  String get currentPersonaId => _currentPersonaId;

  Future<void> _load() async {
    if (_currentPersonaId.isEmpty) {
      _files = [];
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/knowledge_base_$_currentPersonaId.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = json.decode(content);
        _files = jsonList.map((j) => KnowledgeFile.fromJson(j)).toList();
      } else {
        _files = [];
      }
    } catch (e) {
      print('Error loading knowledge base for $_currentPersonaId: $e');
      _files = [];
    }
  }

  Future<void> _save() async {
    if (_currentPersonaId.isEmpty) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/knowledge_base_$_currentPersonaId.json');
      final jsonList = _files.map((f) => f.toJson()).toList();
      await file.writeAsString(json.encode(jsonList));
    } catch (e) {
      print('Error saving knowledge base for $_currentPersonaId: $e');
    }
  }

  List<KnowledgeFile> get files => _files;

  /// Ingest a file: Read -> Chunk -> Summarize -> Store
  Future<KnowledgeFile> ingestFile({
    required String filename,
    required String content,
    required Future<String> Function(String chunk) summarizer,
  }) async {
    // 1. Chunking (Simple char count for now, e.g., 3000 chars)
    const int chunkSize = 3000;
    final chunks = <KnowledgeChunk>[];
    
    for (int i = 0; i < content.length; i += chunkSize) {
      final end = (i + chunkSize < content.length) ? i + chunkSize : content.length;
      final chunkText = content.substring(i, end);
      
      // 2. Summarize Chunk
      final summary = await summarizer(chunkText);
      
      chunks.add(KnowledgeChunk(
        id: '${DateTime.now().millisecondsSinceEpoch}_$i',
        summary: summary,
        content: chunkText,
        index: chunks.length,
      ));
    }

    // 3. Generate Global Summary (Round 2)
    // Handle large files: If combined summaries exceed 8000 chars, do hierarchical summarization
    String? globalSummary;
    if (chunks.length > 1) {
      final allSummaries = chunks.map((c) => c.summary).join('\n\n');
      
      if (allSummaries.length > 8000) {
        // Hierarchical: Split summaries into groups, summarize each, then combine
        const groupSize = 5;
        final intermediateSummaries = <String>[];
        for (int i = 0; i < chunks.length; i += groupSize) {
          final end = (i + groupSize < chunks.length) ? i + groupSize : chunks.length;
          final groupText = chunks.sublist(i, end).map((c) => c.summary).join('\n');
          final groupSummary = await summarizer('Briefly summarize:\n$groupText');
          intermediateSummaries.add(groupSummary);
        }
        globalSummary = await summarizer('Provide a high-level overview:\n${intermediateSummaries.join("\n")}');
      } else {
        globalSummary = await summarizer('Please provide a high-level overview of the following document summaries:\n$allSummaries');
      }
    } else if (chunks.isNotEmpty) {
      globalSummary = chunks.first.summary;
    }

    // Remove existing file with same name to prevent duplicates
    _files.removeWhere((f) => f.filename == filename);

    final newFile = KnowledgeFile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      filename: filename,
      uploadTime: DateTime.now(),
      chunks: chunks,
      globalSummary: globalSummary,
    );

    _files.add(newFile);
    await _save();
    return newFile;
  }

  /// Delete an entire file from knowledge base
  Future<bool> deleteFile(String fileId) async {
    final before = _files.length;
    _files.removeWhere((f) => f.id == fileId);
    if (_files.length < before) {
      await _save();
      return true;
    }
    return false;
  }

  /// Delete a specific chunk from a file
  Future<bool> deleteChunk(String chunkId) async {
    for (var i = 0; i < _files.length; i++) {
      final file = _files[i];
      final chunkIndex = file.chunks.indexWhere((c) => c.id == chunkId);
      if (chunkIndex != -1) {
        final newChunks = List<KnowledgeChunk>.from(file.chunks);
        newChunks.removeAt(chunkIndex);
        
        if (newChunks.isEmpty) {
          // If no chunks left, remove the entire file
          _files.removeAt(i);
        } else {
          // Update file with remaining chunks
          _files[i] = KnowledgeFile(
            id: file.id,
            filename: file.filename,
            uploadTime: file.uploadTime,
            chunks: newChunks,
            globalSummary: file.globalSummary, // Keep old summary, could regenerate but costly
          );
        }
        await _save();
        return true;
      }
    }
    return false;
  }

  /// Clear all knowledge for current persona
  Future<void> clearAll() async {
    _files.clear();
    await _save();
  }

  /// Get all summaries formatted for the Agent's context
  /// Adaptive Strategy: If total content is small, show detailed chunk summaries.
  /// If too large, switch to "Global Summary" mode (Round 2) to save context.
  String getKnowledgeIndex() {
    if (_files.isEmpty) return "No files in knowledge base.";
    
    // 1. Calculate total size of detailed view
    int detailedSize = 0;
    for (var f in _files) {
      detailedSize += '📄 File: ${f.filename}\n'.length;
      for (var c in f.chunks) {
        detailedSize += '  - Chunk ${c.index}: ${c.summary}\n'.length;
      }
    }

    // 2. Decide Mode
    // Threshold: 50,000 chars (user requested limit)
    final bool useCompactMode = detailedSize > 50000;
    
    final buffer = StringBuffer();
    if (useCompactMode) {
      buffer.writeln('📚 Knowledge Base Index (Compact Mode - High Level Summaries)');
      buffer.writeln('Note: Some details are condensed. You can still read specific chunks if needed.');
    }

    for (var file in _files) {
      buffer.writeln('📄 File: ${file.filename} (ID: ${file.id})');
      
      if (useCompactMode && file.globalSummary != null) {
        // Round 2: Show Global Summary + Mini Chunk Hints
        buffer.writeln('  📝 Global Summary: ${file.globalSummary!.replaceAll('\n', ' ')}');
        buffer.writeln('  (Contains ${file.chunks.length} chunks. Use read_knowledge with ID to read details.)'); 
        
        // Show mini-hints so Agent knows WHICH chunk to read
        buffer.writeln('  - Chunk Hints:');
        for (var chunk in file.chunks) {
           String hint = chunk.summary.replaceAll('\n', ' ');
           if (hint.length > 60) hint = '${hint.substring(0, 60)}...';
           buffer.write(' [${chunk.id}]: $hint |');
        }
        buffer.writeln(''); // Newline after hints
      } else {
        // Round 1: Show Detailed Chunk Summaries
        for (var chunk in file.chunks) {
          buffer.writeln('  - Chunk ${chunk.index} (ID: ${chunk.id}): ${chunk.summary.replaceAll('\n', ' ')}');
        }
      }
      buffer.writeln('');
    }
    return buffer.toString();
  }

  /// Retrieve specific chunk content
  String? getChunkContent(String chunkId) {
    for (var file in _files) {
      for (var chunk in file.chunks) {
        if (chunk.id == chunkId) {
          return chunk.content;
        }
      }
    }
    return null;
  }

  /// Get all available chunk IDs (for error recovery suggestions)
  List<String> getAllChunkIds() {
    final ids = <String>[];
    for (var file in _files) {
      for (var chunk in file.chunks) {
        ids.add(chunk.id);
      }
    }
    return ids;
  }

  /// Get knowledge base statistics for UI display
  Map<String, dynamic> getStats() {
    int totalChunks = 0;
    int totalChars = 0;
    for (var file in _files) {
      totalChunks += file.chunks.length;
      for (var chunk in file.chunks) {
        totalChars += chunk.content.length;
      }
    }
    return {
      'fileCount': _files.length,
      'chunkCount': totalChunks,
      'totalChars': totalChars,
      'filenames': _files.map((f) => f.filename).toList(),
    };
  }
}
