class ReferenceItem {
  final String title;
  final String url;
  final String snippet;
  final String sourceName;
  // Optional: image identifier for vision results
  final String? imageId;
  // Category/type: 'web' | 'vision' | 'generated' | 'reflection' | 'hypothesis' | 'system' | 'user_provided'
  final String sourceType;
  
  // === Source Reliability Metadata ===
  // Reliability score: 0.0-1.0 (null = unknown)
  final double? reliability;
  // Source authority level: 'official', 'authoritative', 'news', 'social', 'forum', 'unknown'
  final String? authorityLevel;
  // Content freshness: timestamp when content was published/updated (if known)
  final DateTime? contentDate;
  // Whether this source has been verified/cross-referenced
  final bool isVerified;
  // Potential issues or caveats with this source
  final List<String>? caveats;

  ReferenceItem({
    required this.title,
    required this.url,
    required this.snippet,
    required this.sourceName,
    this.imageId,
    this.sourceType = 'web',
    this.reliability,
    this.authorityLevel,
    this.contentDate,
    this.isVerified = false,
    this.caveats,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'snippet': snippet,
        'sourceName': sourceName,
        'imageId': imageId,
        'sourceType': sourceType,
        'reliability': reliability,
        'authorityLevel': authorityLevel,
        'contentDate': contentDate?.toIso8601String(),
        'isVerified': isVerified,
        'caveats': caveats,
      };

  factory ReferenceItem.fromJson(Map<String, dynamic> json) {
    return ReferenceItem(
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      snippet: json['snippet'] ?? '',
      sourceName: json['sourceName'] ?? '',
      imageId: json['imageId'],
      sourceType: json['sourceType'] ?? 'web',
      reliability: (json['reliability'] as num?)?.toDouble(),
      authorityLevel: json['authorityLevel'],
      contentDate: json['contentDate'] != null ? DateTime.tryParse(json['contentDate']) : null,
      isVerified: json['isVerified'] ?? false,
      caveats: json['caveats'] != null ? List<String>.from(json['caveats']) : null,
    );
  }
  
  /// Get a human-readable reliability indicator
  String get reliabilityIndicator {
    if (reliability == null) return '❓ 未知';
    if (reliability! >= 0.8) return '🟢 高可信';
    if (reliability! >= 0.5) return '🟡 中等';
    return '🔴 低可信';
  }
  
  /// Get authority badge
  String get authorityBadge {
    switch (authorityLevel) {
      case 'official': return '🏛️ 官方';
      case 'authoritative': return '📚 权威';
      case 'news': return '📰 新闻';
      case 'social': return '💬 社交';
      case 'forum': return '🗣️ 论坛';
      default: return '❓ 未知';
    }
  }
  
  /// Check if source might be outdated (>30 days old)
  bool get mightBeOutdated {
    if (contentDate == null) return true; // Unknown date = potentially outdated
    return DateTime.now().difference(contentDate!).inDays > 30;
  }
  
  /// Get freshness indicator
  String get freshnessIndicator {
    if (contentDate == null) return '📅 日期未知';
    final days = DateTime.now().difference(contentDate!).inDays;
    if (days <= 1) return '🆕 今日';
    if (days <= 7) return '📅 本周';
    if (days <= 30) return '📅 本月';
    if (days <= 365) return '📅 今年';
    return '⚠️ 超过一年';
  }
}
