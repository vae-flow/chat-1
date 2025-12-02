enum AgentActionType { answer, search, draw, vision, reflect, hypothesize, clarify, save_file, system_control, read_knowledge, delete_knowledge }

/// Information sufficiency assessment
class InfoSufficiency {
  final bool isSufficient;
  final List<String> missingInfo; // What specific info is missing
  final List<String> unreliableSources; // Sources that need verification
  final String? suggestedAction; // What to do: 'search', 'ask_user', 'verify', 'proceed_with_caveats'
  final String? clarifyQuestion; // If ask_user, what to ask

  InfoSufficiency({
    required this.isSufficient,
    this.missingInfo = const [],
    this.unreliableSources = const [],
    this.suggestedAction,
    this.clarifyQuestion,
  });

  factory InfoSufficiency.fromJson(Map<String, dynamic> json) {
    return InfoSufficiency(
      isSufficient: json['is_sufficient'] ?? true,
      missingInfo: json['missing_info'] != null 
        ? List<String>.from(json['missing_info']) 
        : [],
      unreliableSources: json['unreliable_sources'] != null
        ? List<String>.from(json['unreliable_sources'])
        : [],
      suggestedAction: json['suggested_action'],
      clarifyQuestion: json['clarify_question'],
    );
  }
}

class AgentDecision {
  final AgentActionType type;
  final String? content; // For answer text or draw prompt or vision analysis prompt or file content
  final String? query;   // For search query
  final String? filename; // For save_file action
  final String? reason;  // The "Thought" - why this decision was made
  final List<Map<String, dynamic>>? reminders; // Preserved feature
  final bool continueAfter; // If true, don't break the loop after this action
  
  // Deep Think enhancements
  final double? confidence; // 0.0-1.0, self-assessed confidence in this decision
  final List<String>? uncertainties; // Known gaps or risks
  final List<String>? hypotheses; // Alternative approaches considered
  final String? selectedHypothesis; // Which hypothesis was chosen and why
  
  // Information Sufficiency (Source Reliability)
  final InfoSufficiency? infoSufficiency; // Assessment of whether we have enough reliable info
  final List<String>? sourceCaveats; // Warnings about source reliability to include in answer

  AgentDecision({
    required this.type,
    this.content,
    this.query,
    this.filename,
    this.reason,
    this.reminders,
    this.continueAfter = false,
    this.confidence,
    this.uncertainties,
    this.hypotheses,
    this.selectedHypothesis,
    this.infoSufficiency,
    this.sourceCaveats,
  });

  factory AgentDecision.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'answer';
    AgentActionType type;
    switch (typeStr) {
      case 'search': type = AgentActionType.search; break;
      case 'draw': type = AgentActionType.draw; break;
      case 'vision': type = AgentActionType.vision; break;
      case 'reflect': type = AgentActionType.reflect; break;
      case 'hypothesize': type = AgentActionType.hypothesize; break;
      case 'clarify': type = AgentActionType.clarify; break;
      case 'save_file': type = AgentActionType.save_file; break;
      case 'system_control': type = AgentActionType.system_control; break;
      case 'read_knowledge': type = AgentActionType.read_knowledge; break;
      case 'delete_knowledge': type = AgentActionType.delete_knowledge; break;
      default: type = AgentActionType.answer;
    }

    return AgentDecision(
      type: type,
      content: json['content'],
      query: json['query'],
      filename: json['filename'],
      reason: json['reason'],
      reminders: json['reminders'] != null 
        ? List<Map<String, dynamic>>.from(json['reminders'])
        : null,
      continueAfter: json['continue'] == true,
      confidence: (json['confidence'] as num?)?.toDouble(),
      uncertainties: json['uncertainties'] != null
        ? List<String>.from(json['uncertainties'])
        : null,
      hypotheses: json['hypotheses'] != null
        ? List<String>.from(json['hypotheses'])
        : null,
      selectedHypothesis: json['selected_hypothesis'],
      infoSufficiency: json['info_sufficiency'] != null
        ? InfoSufficiency.fromJson(json['info_sufficiency'])
        : null,
      sourceCaveats: json['source_caveats'] != null
        ? List<String>.from(json['source_caveats'])
        : null,
    );
  }
  
  /// Check if confidence is below threshold (needs more work)
  bool get needsMoreWork => (confidence ?? 1.0) < 0.7;
  
  /// Check if there are critical uncertainties
  bool get hasCriticalUncertainties => 
    uncertainties != null && uncertainties!.any((u) => u.contains('关键') || u.contains('critical'));
  
  /// Check if we should ask user for more info
  bool get shouldAskUser => 
    infoSufficiency?.suggestedAction == 'ask_user' && 
    infoSufficiency?.clarifyQuestion != null;
  
  /// Check if sources are unreliable
  bool get hasUnreliableSources =>
    infoSufficiency?.unreliableSources.isNotEmpty == true;
  
  /// Convert to JSON for persistence
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'content': content,
      'query': query,
      'filename': filename,
      'reason': reason,
      'reminders': reminders,
      'continue': continueAfter,
      'confidence': confidence,
      'uncertainties': uncertainties,
      'hypotheses': hypotheses,
      'selected_hypothesis': selectedHypothesis,
      'info_sufficiency': infoSufficiency != null ? {
        'is_sufficient': infoSufficiency!.isSufficient,
        'missing_info': infoSufficiency!.missingInfo,
        'unreliable_sources': infoSufficiency!.unreliableSources,
        'suggested_action': infoSufficiency!.suggestedAction,
        'clarify_question': infoSufficiency!.clarifyQuestion,
      } : null,
      'source_caveats': sourceCaveats,
    };
  }
}
