enum AgentActionType { answer, search, recall_search, read_url, draw, vision, ocr, reflect, hypothesize, clarify, save_file, system_control, search_knowledge, read_knowledge, delete_knowledge, take_note }

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

/// Task complexity assessment for meta-cognition
class TaskAssessment {
  final String complexity; // 'simple', 'medium', 'complex', 'beyond_session'
  final int estimatedPhases; // Total number of phases needed
  final int currentPhase; // Current phase (1-indexed)
  final String? phaseDescription; // Description of current phase
  final bool needsUserConfirmation; // Whether to ask user before proceeding

  TaskAssessment({
    required this.complexity,
    this.estimatedPhases = 1,
    this.currentPhase = 1,
    this.phaseDescription,
    this.needsUserConfirmation = false,
  });

  factory TaskAssessment.fromJson(Map<String, dynamic> json) {
    return TaskAssessment(
      complexity: json['complexity'] ?? 'simple',
      estimatedPhases: json['estimated_phases'] ?? 1,
      currentPhase: json['current_phase'] ?? 1,
      phaseDescription: json['phase_description'],
      needsUserConfirmation: json['needs_user_confirmation'] ?? false,
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'complexity': complexity,
      'estimated_phases': estimatedPhases,
      'current_phase': currentPhase,
      'phase_description': phaseDescription,
      'needs_user_confirmation': needsUserConfirmation,
    };
  }
  
  /// Check if this is a complex multi-phase task
  bool get isMultiPhase => estimatedPhases > 1;
  
  /// Check if task exceeds single session capability
  bool get exceedsSession => complexity == 'beyond_session';
  
  /// Get progress string
  String get progressString => isMultiPhase ? '第$currentPhase阶段/共$estimatedPhases阶段' : '';
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
  
  // Task Assessment (Meta-cognition)
  final TaskAssessment? taskAssessment; // Assessment of task complexity and progress

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
    this.taskAssessment,
  });

  factory AgentDecision.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'answer';
    AgentActionType type;
    switch (typeStr) {
      case 'search': type = AgentActionType.search; break;
      case 'read_url': type = AgentActionType.read_url; break;
      case 'draw': type = AgentActionType.draw; break;
      case 'vision': type = AgentActionType.vision; break;
      case 'ocr': type = AgentActionType.ocr; break;
      case 'reflect': type = AgentActionType.reflect; break;
      case 'hypothesize': type = AgentActionType.hypothesize; break;
      case 'clarify': type = AgentActionType.clarify; break;
      case 'save_file': type = AgentActionType.save_file; break;
      case 'system_control': type = AgentActionType.system_control; break;
      case 'search_knowledge': type = AgentActionType.search_knowledge; break;
      case 'read_knowledge': type = AgentActionType.read_knowledge; break;
      case 'delete_knowledge': type = AgentActionType.delete_knowledge; break;
      case 'take_note': type = AgentActionType.take_note; break;
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
      taskAssessment: json['task_assessment'] != null
        ? TaskAssessment.fromJson(json['task_assessment'])
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
    
  /// Check if task needs user confirmation
  bool get needsUserConfirmation =>
    taskAssessment?.needsUserConfirmation == true;
  
  /// Check if task is complex (medium or higher)
  bool get isComplexTask =>
    taskAssessment?.complexity == 'medium' ||
    taskAssessment?.complexity == 'complex' ||
    taskAssessment?.complexity == 'beyond_session';
  
  /// Check if this is a multi-phase task
  bool get isMultiPhaseTask =>
    taskAssessment?.isMultiPhase == true;
  
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
      'task_assessment': taskAssessment?.toJson(),
    };
  }

  AgentDecision copyWith({
    AgentActionType? type,
    String? content,
    String? query,
    String? filename,
    String? reason,
    List<Map<String, dynamic>>? reminders,
    bool? continueAfter,
    double? confidence,
    List<String>? uncertainties,
    List<String>? hypotheses,
    String? selectedHypothesis,
    InfoSufficiency? infoSufficiency,
    List<String>? sourceCaveats,
    TaskAssessment? taskAssessment,
  }) {
    return AgentDecision(
      type: type ?? this.type,
      content: content ?? this.content,
      query: query ?? this.query,
      filename: filename ?? this.filename,
      reason: reason ?? this.reason,
      reminders: reminders ?? this.reminders,
      continueAfter: continueAfter ?? this.continueAfter,
      confidence: confidence ?? this.confidence,
      uncertainties: uncertainties ?? this.uncertainties,
      hypotheses: hypotheses ?? this.hypotheses,
      selectedHypothesis: selectedHypothesis ?? this.selectedHypothesis,
      infoSufficiency: infoSufficiency ?? this.infoSufficiency,
      sourceCaveats: sourceCaveats ?? this.sourceCaveats,
      taskAssessment: taskAssessment ?? this.taskAssessment,
    );
  }
}

/// A complete execution plan with multiple steps
/// Generated after three-pass thinking, contains multiple API calls
class AgentPlan {
  final String userIntent;        // P1: What user really wants
  final String capabilityReview;  // P2: Which tools/APIs will be used
  final String expectedOutcome;   // P3: What we expect to achieve
  final List<AgentStep> steps;    // Ordered list of steps to execute
  final double overallConfidence; // Confidence in the entire plan
  final String? fallbackStrategy; // What to do if plan fails

  AgentPlan({
    required this.userIntent,
    required this.capabilityReview,
    required this.expectedOutcome,
    required this.steps,
    this.overallConfidence = 0.8,
    this.fallbackStrategy,
  });

  factory AgentPlan.fromJson(Map<String, dynamic> json) {
    // Parse steps array
    List<AgentStep> steps = [];
    if (json['steps'] != null) {
      steps = (json['steps'] as List).map((s) => AgentStep.fromJson(s)).toList();
    } else if (json['plan'] != null) {
      // Alternative format: plan array
      steps = (json['plan'] as List).map((s) => AgentStep.fromJson(s)).toList();
    }
    
    return AgentPlan(
      userIntent: json['user_intent'] ?? json['P1'] ?? '',
      capabilityReview: json['capability_review'] ?? json['P2'] ?? '',
      expectedOutcome: json['expected_outcome'] ?? json['P3'] ?? '',
      steps: steps,
      overallConfidence: (json['confidence'] as num?)?.toDouble() ?? 0.8,
      fallbackStrategy: json['fallback'] ?? json['fallback_strategy'],
    );
  }

  /// Check if this is a multi-step plan
  bool get isMultiStep => steps.length > 1;
  
  /// Get total estimated API calls
  int get totalApiCalls => steps.where((s) => s.requiresApi).length;
  
  /// Convert single-step legacy format to plan
  static AgentPlan fromSingleDecision(AgentDecision decision) {
    return AgentPlan(
      userIntent: 'Single action request',
      capabilityReview: 'Using ${decision.type.name}',
      expectedOutcome: decision.reason ?? 'Complete user request',
      steps: [
        AgentStep(
          stepNumber: 1,
          action: decision.type,
          purpose: decision.reason ?? '',
          query: decision.query,
          content: decision.content,
          filename: decision.filename,
          dependsOn: [],
          continueOnFail: false,
        )
      ],
      overallConfidence: decision.confidence ?? 0.8,
    );
  }
}

/// A single step in an execution plan
class AgentStep {
  final int stepNumber;
  final AgentActionType action;
  final String purpose;           // Why this step
  final String? query;            // For search
  final String? content;          // For answer/draw/etc
  final String? filename;         // For save_file
  final String? url;              // For read_url
  final List<int> dependsOn;      // Which steps must complete first
  final bool continueOnFail;      // Continue plan even if this fails
  final String? outputVariable;   // Name to store result for later steps

  AgentStep({
    required this.stepNumber,
    required this.action,
    required this.purpose,
    this.query,
    this.content,
    this.filename,
    this.url,
    this.dependsOn = const [],
    this.continueOnFail = false,
    this.outputVariable,
  });

  factory AgentStep.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] ?? json['action'] ?? 'answer';
    AgentActionType action;
    switch (typeStr) {
      case 'search': action = AgentActionType.search; break;
      case 'read_url': action = AgentActionType.read_url; break;
      case 'draw': action = AgentActionType.draw; break;
      case 'vision': action = AgentActionType.vision; break;
      case 'ocr': action = AgentActionType.ocr; break;
      case 'reflect': action = AgentActionType.reflect; break;
      case 'hypothesize': action = AgentActionType.hypothesize; break;
      case 'clarify': action = AgentActionType.clarify; break;
      case 'save_file': action = AgentActionType.save_file; break;
      case 'system_control': action = AgentActionType.system_control; break;
      case 'search_knowledge': action = AgentActionType.search_knowledge; break;
      case 'read_knowledge': action = AgentActionType.read_knowledge; break;
      case 'delete_knowledge': action = AgentActionType.delete_knowledge; break;
      case 'take_note': action = AgentActionType.take_note; break;
      default: action = AgentActionType.answer;
    }

    return AgentStep(
      stepNumber: json['step'] ?? json['step_number'] ?? 1,
      action: action,
      purpose: json['purpose'] ?? json['reason'] ?? '',
      query: json['query'],
      content: json['content'],
      filename: json['filename'],
      url: json['url'],
      dependsOn: json['depends_on'] != null 
        ? List<int>.from(json['depends_on']) 
        : [],
      continueOnFail: json['continue_on_fail'] ?? false,
      outputVariable: json['output_as'] ?? json['output_variable'],
    );
  }

  /// Convert to AgentDecision for execution
  AgentDecision toDecision() {
    return AgentDecision(
      type: action,
      query: query,
      content: content,
      filename: filename,
      reason: purpose,
      continueAfter: true, // Plan manages continuation
    );
  }
  
  /// Check if this step requires an API call
  bool get requiresApi => 
    action == AgentActionType.search ||
    action == AgentActionType.draw ||
    action == AgentActionType.read_url ||
    action == AgentActionType.vision ||
    action == AgentActionType.ocr;
}
