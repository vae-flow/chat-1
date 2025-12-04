enum TaskStatus { pending, running, success, failed, expired }

class Task {
  final String id;
  final String type; // e.g., search/deep_read/vision/ocr/analysis
  final TaskStatus status;
  final Map<String, dynamic>? payload; // original request payload
  final String? result; // normalized result text/snippet
  final String? error;
  final String? statusUrl; // optional poll endpoint
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool delivered; // whether results were injected into sessionRefs

  Task({
    required this.id,
    required this.type,
    required this.status,
    this.payload,
    this.result,
    this.error,
    this.statusUrl,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.delivered = false,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Task copyWith({
    TaskStatus? status,
    Map<String, dynamic>? payload,
    String? result,
    String? error,
    String? statusUrl,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? delivered,
  }) {
    return Task(
      id: id,
      type: type,
      status: status ?? this.status,
      payload: payload ?? this.payload,
      result: result ?? this.result,
      error: error ?? this.error,
      statusUrl: statusUrl ?? this.statusUrl,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      delivered: delivered ?? this.delivered,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'status': status.name,
        'payload': payload,
        'result': result,
        'error': error,
        'statusUrl': statusUrl,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'delivered': delivered,
      };

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id'],
      type: json['type'] ?? 'generic',
      status: TaskStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => TaskStatus.pending,
      ),
      payload: json['payload'] != null ? Map<String, dynamic>.from(json['payload']) : null,
      result: json['result'],
      error: json['error'],
      statusUrl: json['statusUrl'],
      createdAt: json['createdAt'] != null ? DateTime.tryParse(json['createdAt']) ?? DateTime.now() : DateTime.now(),
      updatedAt: json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt']) ?? DateTime.now() : DateTime.now(),
      delivered: json['delivered'] ?? false,
    );
  }
}
