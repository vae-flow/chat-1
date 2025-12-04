import 'dart:convert';

class KnowledgeChunk {
  final String id;
  final String summary;
  final String content;
  final int index;
  final bool needsResummary; // 标记是否需要重新摘要（摘要失败时为 true）

  KnowledgeChunk({
    required this.id,
    required this.summary,
    required this.content,
    required this.index,
    this.needsResummary = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'summary': summary,
    'content': content,
    'index': index,
    'needs_resummary': needsResummary,
  };

  factory KnowledgeChunk.fromJson(Map<String, dynamic> json) {
    return KnowledgeChunk(
      id: json['id'],
      summary: json['summary'],
      content: json['content'],
      index: json['index'],
      needsResummary: json['needs_resummary'] ?? false,
    );
  }
  
  /// 序列化为 JSON 字符串（用于持久化或日志）
  String toJsonString() => json.encode(toJson());
  
  /// 从 JSON 字符串反序列化
  static KnowledgeChunk fromJsonString(String jsonStr) {
    return KnowledgeChunk.fromJson(json.decode(jsonStr));
  }
}

class KnowledgeFile {
  final String id;
  final String filename;
  final DateTime uploadTime;
  final List<KnowledgeChunk> chunks;
  final String? globalSummary; // New: High-level summary of the whole file

  KnowledgeFile({
    required this.id,
    required this.filename,
    required this.uploadTime,
    required this.chunks,
    this.globalSummary,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'filename': filename,
    'upload_time': uploadTime.toIso8601String(),
    'chunks': chunks.map((c) => c.toJson()).toList(),
    'global_summary': globalSummary,
  };

  factory KnowledgeFile.fromJson(Map<String, dynamic> json) {
    return KnowledgeFile(
      id: json['id'],
      filename: json['filename'],
      uploadTime: DateTime.parse(json['upload_time']),
      chunks: (json['chunks'] as List)
          .map((c) => KnowledgeChunk.fromJson(c))
          .toList(),
      globalSummary: json['global_summary'],
    );
  }
  
  /// 序列化为 JSON 字符串（用于持久化或日志）
  String toJsonString() => json.encode(toJson());
  
  /// 从 JSON 字符串反序列化
  static KnowledgeFile fromJsonString(String jsonStr) {
    return KnowledgeFile.fromJson(json.decode(jsonStr));
  }
}
