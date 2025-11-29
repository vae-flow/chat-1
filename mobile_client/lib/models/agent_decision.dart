enum AgentActionType { answer, search, draw }

class AgentDecision {
  final AgentActionType type;
  final String? content; // For answer text or draw prompt
  final String? query;   // For search query
  final String? reason;  // The "Thought" - why this decision was made
  final List<Map<String, dynamic>>? reminders; // Preserved feature

  AgentDecision({
    required this.type,
    this.content,
    this.query,
    this.reason,
    this.reminders,
  });

  factory AgentDecision.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'answer';
    AgentActionType type;
    switch (typeStr) {
      case 'search': type = AgentActionType.search; break;
      case 'draw': type = AgentActionType.draw; break;
      default: type = AgentActionType.answer;
    }

    return AgentDecision(
      type: type,
      content: json['content'],
      query: json['query'],
      reason: json['reason'],
      reminders: json['reminders'] != null 
        ? List<Map<String, dynamic>>.from(json['reminders'])
        : null,
    );
  }
}
