import 'reference_item.dart';

class ChatMessage {
  final String id; // Unique ID for indexing and deduplication
  final String role;
  final String content;
  final String? imageUrl;
  final String? localImagePath;
  final bool isMemory;
  final List<ReferenceItem>? references;
  
  // Compression & Archiving State
  final bool isArchived; // Has been written to chat_archive.jsonl
  final bool isCompressed; // Has been summarized by LLM
  final int? originalLength; // Original length before compression
  final double? compressionRatio; // The target ratio used (e.g. 0.7)

  ChatMessage(this.role, this.content, {
    String? id,
    this.imageUrl, 
    this.localImagePath, 
    this.isMemory = false,
    this.references,
    this.isArchived = false,
    this.isCompressed = false,
    this.originalLength,
    this.compressionRatio,
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString();

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'imageUrl': imageUrl,
        'localImagePath': localImagePath,
        'isMemory': isMemory,
        'references': references?.map((e) => e.toJson()).toList(),
        'isArchived': isArchived,
        'isCompressed': isCompressed,
        'originalLength': originalLength,
        'compressionRatio': compressionRatio,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      json['role'],
      json['content'],
      id: json['id'],
      imageUrl: json['imageUrl'],
      localImagePath: json['localImagePath'],
      isMemory: json['isMemory'] ?? false,
      references: json['references'] != null
          ? (json['references'] as List).map((e) => ReferenceItem.fromJson(e)).toList()
          : null,
      isArchived: json['isArchived'] ?? false,
      isCompressed: json['isCompressed'] ?? false,
      originalLength: json['originalLength'],
      compressionRatio: json['compressionRatio']?.toDouble(),
    );
  }
  
  // Helper to create a copy with updated fields
  ChatMessage copyWith({
    String? content,
    bool? isArchived,
    bool? isCompressed,
    int? originalLength,
    double? compressionRatio,
  }) {
    return ChatMessage(
      role,
      content ?? this.content,
      id: id,
      imageUrl: imageUrl,
      localImagePath: localImagePath,
      isMemory: isMemory,
      references: references,
      isArchived: isArchived ?? this.isArchived,
      isCompressed: isCompressed ?? this.isCompressed,
      originalLength: originalLength ?? this.originalLength,
      compressionRatio: compressionRatio ?? this.compressionRatio,
    );
  }
}
