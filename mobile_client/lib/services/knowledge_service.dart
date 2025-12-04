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
  
  /// 检查服务是否已初始化
  bool get isInitialized => _initialized;

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
      
      // 检测是否是 fallback 摘要（API 摘要失败时生成的）
      final isFallback = summary.startsWith('[Fallback Summary');
      
      chunks.add(KnowledgeChunk(
        id: '${DateTime.now().millisecondsSinceEpoch}_$i',
        summary: summary,
        content: chunkText,
        index: chunks.length,
        needsResummary: isFallback, // 标记需要重新摘要
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
        globalSummary = await summarizer('Provide a HIGH-LEVEL overview in about 100-150 characters (one sentence). Be concise:\n${intermediateSummaries.join("\n")}');
      } else {
        globalSummary = await summarizer('Summarize in ONE concise sentence (100-150 chars max). What is this file about?\n$allSummaries');
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

  /// 获取需要重新摘要的 chunk 列表
  List<Map<String, dynamic>> getPendingResummaryChunks() {
    final pending = <Map<String, dynamic>>[];
    for (var file in _files) {
      for (var chunk in file.chunks) {
        if (chunk.needsResummary) {
          pending.add({
            'fileId': file.id,
            'filename': file.filename,
            'chunkId': chunk.id,
            'chunkIndex': chunk.index,
          });
        }
      }
    }
    return pending;
  }

  /// 重新摘要单个 chunk
  Future<bool> resummaryChunk({
    required String chunkId,
    required Future<String> Function(String chunk) summarizer,
  }) async {
    for (var i = 0; i < _files.length; i++) {
      final file = _files[i];
      final chunkIndex = file.chunks.indexWhere((c) => c.id == chunkId);
      if (chunkIndex != -1) {
        final chunk = file.chunks[chunkIndex];
        final newSummary = await summarizer(chunk.content);
        final isFallback = newSummary.startsWith('[Fallback Summary');
        
        // 创建更新后的 chunk
        final updatedChunk = KnowledgeChunk(
          id: chunk.id,
          summary: newSummary,
          content: chunk.content,
          index: chunk.index,
          needsResummary: isFallback,
        );
        
        // 更新 chunks 列表
        final newChunks = List<KnowledgeChunk>.from(file.chunks);
        newChunks[chunkIndex] = updatedChunk;
        
        _files[i] = KnowledgeFile(
          id: file.id,
          filename: file.filename,
          uploadTime: file.uploadTime,
          chunks: newChunks,
          globalSummary: file.globalSummary,
        );
        
        await _save();
        return !isFallback; // 返回是否成功（非 fallback）
      }
    }
    return false;
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

  /// Check if knowledge base has any content
  bool get hasKnowledge => _files.isNotEmpty;

  /// Search chunks by keywords, return matching chunk IDs with their summaries
  /// Returns results in batches of [batchSize] for progressive disclosure
  /// 
  /// [keywords]: Comma-separated search terms
  /// [batchIndex]: Which batch to return (0-indexed)
  /// [batchSize]: Number of results per batch (default 5)
  /// 
  /// Returns a map with:
  /// - 'results': List of matching chunks with id, filename, summary
  /// - 'totalMatches': Total number of matches found
  /// - 'hasMore': Whether there are more results to fetch
  /// - 'nextBatchIndex': The next batch index to request
  Map<String, dynamic> searchChunks({
    required String keywords,
    int batchIndex = 0,
    int batchSize = 5,
  }) {
    if (_files.isEmpty) {
      return {
        'results': <Map<String, dynamic>>[],
        'totalMatches': 0,
        'hasMore': false,
        'nextBatchIndex': 0,
        'message': 'Knowledge base is empty. No files have been uploaded.',
      };
    }

    // Parse keywords (comma or space separated, lowercase for matching)
    final keywordList = keywords
        .toLowerCase()
        .split(RegExp(r'[,\s]+'))
        .where((k) => k.isNotEmpty && k.length > 1) // Skip single chars
        .toList();

    if (keywordList.isEmpty) {
      return {
        'results': <Map<String, dynamic>>[],
        'totalMatches': 0,
        'hasMore': false,
        'nextBatchIndex': 0,
        'message': 'No valid keywords provided. Use comma-separated search terms.',
      };
    }

    // Collect all matching chunks with their scores
    final matches = <Map<String, dynamic>>[];
    
    for (var file in _files) {
      for (var chunk in file.chunks) {
        final summaryLower = chunk.summary.toLowerCase();
        final filenameLower = file.filename.toLowerCase();
        
        // Calculate match score (how many keywords match)
        int matchScore = 0;
        final matchedKeywords = <String>[];
        
        for (var keyword in keywordList) {
          if (summaryLower.contains(keyword) || filenameLower.contains(keyword)) {
            matchScore++;
            matchedKeywords.add(keyword);
          }
        }
        
        if (matchScore > 0) {
          matches.add({
            'id': chunk.id,
            'filename': file.filename,
            'fileId': file.id,
            'chunkIndex': chunk.index,
            'summary': chunk.summary,
            'score': matchScore,
            'matchedKeywords': matchedKeywords,
          });
        }
      }
    }

    // Sort by score (most matches first), then by chunk index
    matches.sort((a, b) {
      final scoreCompare = (b['score'] as int).compareTo(a['score'] as int);
      if (scoreCompare != 0) return scoreCompare;
      return (a['chunkIndex'] as int).compareTo(b['chunkIndex'] as int);
    });

    // Calculate pagination
    final totalMatches = matches.length;
    final startIndex = batchIndex * batchSize;
    final endIndex = (startIndex + batchSize).clamp(0, totalMatches);
    
    if (startIndex >= totalMatches) {
      return {
        'results': <Map<String, dynamic>>[],
        'totalMatches': totalMatches,
        'hasMore': false,
        'nextBatchIndex': batchIndex,
        'message': 'No more results. All $totalMatches matches have been shown.',
      };
    }

    final batchResults = matches.sublist(startIndex, endIndex);
    final hasMore = endIndex < totalMatches;

    return {
      'results': batchResults,
      'totalMatches': totalMatches,
      'currentBatch': batchIndex,
      'hasMore': hasMore,
      'nextBatchIndex': hasMore ? batchIndex + 1 : batchIndex,
      'remainingCount': totalMatches - endIndex,
    };
  }

  /// Get a brief overview of what's in the knowledge base (for Agent awareness)
  /// This is a lightweight summary, not the full index
  String getKnowledgeOverview() {
    if (_files.isEmpty) {
      return 'Knowledge base is empty.';
    }
    
    final buffer = StringBuffer();
    buffer.writeln('📚 Knowledge Base Overview:');
    buffer.writeln('Total: ${_files.length} file(s)');
    buffer.writeln('');
    buffer.writeln('⚠️ IMPORTANT: User has uploaded files to knowledge base!');
    buffer.writeln('   If user\'s question relates to ANY of these topics, you MUST use search_knowledge first.');
    buffer.writeln('');
    
    for (var file in _files) {
      buffer.writeln('  📄 ${file.filename} (${file.chunks.length} chunks)');
      // Add global summary if available (helps Agent decide when to search)
      if (file.globalSummary != null && file.globalSummary!.isNotEmpty) {
        buffer.writeln('     └─ 内容: ${file.globalSummary!.replaceAll('\n', ' ')}');
      }
    }
    
    buffer.writeln('');
    buffer.writeln('🔑 DECISION RULE:');
    buffer.writeln('   - User asks about file content → search_knowledge → read_knowledge → answer');
    buffer.writeln('   - User asks to modify/expand/summarize file → search_knowledge → read_knowledge → answer/save_file');
    buffer.writeln('   - Unrelated question → use other tools or answer directly');
    return buffer.toString();
  }
}
