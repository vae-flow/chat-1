import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reference_item.dart';

/// Manages search references and formatting
class ReferenceManager {
  
  /// 带重试机制的 HTTP 请求辅助方法
  Future<http.Response> _httpWithRetry(
    Future<http.Response> Function() request, {
    int maxRetries = 2,
    int baseDelayMs = 1000,
  }) async {
    int attempt = 0;
    http.Response? lastResponse;
    Object? lastError;
    
    while (attempt <= maxRetries) {
      try {
        final response = await request();
        
        // 成功或客户端错误不重试
        if (response.statusCode == 200 || 
            response.statusCode == 400 || 
            response.statusCode == 401 ||
            response.statusCode == 403) {
          return response;
        }
        
        // 服务器错误或限流可重试
        if (response.statusCode >= 500 || response.statusCode == 429) {
          lastResponse = response;
          debugPrint('🔄 搜索 API 失败 (${response.statusCode})，重试 ${attempt + 1}/$maxRetries...');
        } else {
          return response;
        }
      } catch (e) {
        lastError = e;
        debugPrint('🔄 搜索 API 异常: $e，重试 ${attempt + 1}/$maxRetries...');
      }
      
      attempt++;
      if (attempt <= maxRetries) {
        await Future.delayed(Duration(milliseconds: baseDelayMs * attempt));
      }
    }
    
    if (lastResponse != null) return lastResponse;
    throw lastError ?? Exception('搜索 API 请求失败');
  }
  
  Future<List<ReferenceItem>> search(String query) async {
    final prefs = await SharedPreferences.getInstance();
    var provider = prefs.getString('search_provider') ?? 'auto';
    final exaKey = prefs.getString('exa_key') ?? '';
    final youKey = prefs.getString('you_key') ?? '';
    final braveKey = prefs.getString('brave_key') ?? '';
    
    // Load custom base URLs (optional)
    final exaBase = prefs.getString('exa_base') ?? 'https://api.exa.ai';
    final youBase = prefs.getString('you_base') ?? 'https://api.ydc-index.io';
    final braveBase = prefs.getString('brave_base') ?? 'https://api.search.brave.com';

    // Auto-select provider based on available keys
    if (provider == 'auto') {
      if (exaKey.isNotEmpty) {
        provider = 'exa';
      } else if (youKey.isNotEmpty) {
        provider = 'you';
      } else if (braveKey.isNotEmpty) {
        provider = 'brave';
      } else {
        // No keys available
        throw Exception('未配置搜索 API Key。请在设置中配置 Exa, You.com 或 Brave Search 的密钥。');
      }
    }

    try {
      switch (provider) {
        case 'exa':
          return _searchExa(query, exaKey, exaBase);
        case 'you':
          return _searchYou(query, youKey, youBase);
        case 'brave':
          return _searchBrave(query, braveKey, braveBase);
        default:
           throw Exception('未知的搜索提供商: $provider');
      }
    } catch (e) {
      debugPrint('Search error ($provider): $e');
      // Re-throw to let the UI handle it or show error
      rethrow; 
    }
  }

  Future<List<ReferenceItem>> _searchExa(String query, String key, String baseUrl) async {
    if (key.isEmpty) throw Exception('Exa Key not configured');
    final uri = Uri.parse('$baseUrl/search');
    
    final resp = await _httpWithRetry(() => http.post(
      uri,
      headers: {
        'x-api-key': key,
        'Content-Type': 'application/json',
      },
      body: json.encode({
        'query': query,
        'numResults': 8,
        'useAutoprompt': true,
        'contents': {'text': true} 
      }),
    ).timeout(const Duration(seconds: 60)));
    
    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final results = data['results'] as List;
      return results.map((r) {
        final url = r['url'] ?? '';
        final publishedDate = r['publishedDate'] != null 
          ? DateTime.tryParse(r['publishedDate']) 
          : null;
        return ReferenceItem(
          title: r['title'] ?? 'No Title',
          url: url,
          snippet: r['text'] != null ? (r['text'] as String).substring(0, (r['text'] as String).length.clamp(0, 6000)).replaceAll('\n', ' ') : '',
          sourceName: 'Exa.ai',
          reliability: _estimateReliability(url),
          authorityLevel: _detectAuthorityLevel(url),
          contentDate: publishedDate,
        );
      }).toList();
    }
    throw Exception('Exa API Error: ${resp.statusCode}');
  }

  Future<List<ReferenceItem>> _searchYou(String query, String key, String baseUrl) async {
    if (key.isEmpty) throw Exception('You.com Key not configured');
    
    // Fix: Use 'count' parameter as per documentation
    // Ensure URL handles /v1 if not present in baseUrl, or assume user configures it.
    // We will use the baseUrl as provided, assuming it includes /v1 if needed (updated in Settings).
    final uri = Uri.parse('$baseUrl/search?query=${Uri.encodeComponent(query)}&count=8');
    
    final resp = await _httpWithRetry(() => http.get(
      uri,
      headers: {'X-API-Key': key},
    ).timeout(const Duration(seconds: 60)));

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      
      // Robust parsing: try multiple known response formats
      List<dynamic> hits = [];
      
      // Format 1: results.web (RAG API)
      if (data['results'] != null && data['results']['web'] is List) {
        hits = data['results']['web'];
      }
      // Format 2: hits (Search API legacy)
      else if (data['hits'] is List) {
        hits = data['hits'];
      }
      // Format 3: webPages.value (alternative format)
      else if (data['webPages'] != null && data['webPages']['value'] is List) {
        hits = data['webPages']['value'];
      }
      // Format 4: organic (another variant)
      else if (data['organic'] is List) {
        hits = data['organic'];
      }
      // Format 5: direct array at root
      else if (data is List) {
        hits = data;
      }
      
      debugPrint('You.com parsed ${hits.length} results');

      return hits.map((h) {
        final url = h['url'] ?? h['link'] ?? '';
        return ReferenceItem(
          title: h['title'] ?? h['name'] ?? 'No Title',
          url: url,
          snippet: (h['snippets'] as List?)?.join(' ') ?? h['description'] ?? h['snippet'] ?? h['text'] ?? '',
          sourceName: 'You.com',
          reliability: _estimateReliability(url),
          authorityLevel: _detectAuthorityLevel(url),
        );
      }).toList();
    }
    // Add more detailed error logging
    debugPrint('You.com Error Body: ${resp.body}');
    throw Exception('You.com API Error: ${resp.statusCode} - ${resp.body}');
  }

  Future<List<ReferenceItem>> _searchBrave(String query, String key, String baseUrl) async {
    if (key.isEmpty) throw Exception('Brave Key not configured');
    final uri = Uri.parse('$baseUrl/res/v1/web/search?q=${Uri.encodeComponent(query)}&count=8');
    
    final resp = await _httpWithRetry(() => http.get(
      uri,
      headers: {
        'X-Subscription-Token': key,
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: 60)));

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      
      // Robust parsing for Brave responses
      List<dynamic> results = [];
      if (data['web'] != null && data['web']['results'] is List) {
        results = data['web']['results'];
      } else if (data['results'] is List) {
        results = data['results'];
      }
      
      debugPrint('Brave parsed ${results.length} results');
      
      return results.map((r) {
        final url = r['url'] ?? '';
        final age = r['age']; // Brave provides age info
        DateTime? contentDate;
        if (age != null) {
          // Parse relative age like "2 days ago", "1 week ago"
          contentDate = _parseRelativeAge(age);
        }
        return ReferenceItem(
          title: r['title'] ?? 'No Title',
          url: url,
          snippet: r['description'] ?? r['snippet'] ?? '',
          sourceName: 'Brave',
          reliability: _estimateReliability(url),
          authorityLevel: _detectAuthorityLevel(url),
          contentDate: contentDate,
        );
      }).toList();
    }
    // Add more detailed error logging
    debugPrint('Brave Error Body: ${resp.body}');
    throw Exception('Brave API Error: ${resp.statusCode} - ${resp.body}');
  }
  
  /// Estimate reliability based on URL domain
  double _estimateReliability(String url) {
    final lowercaseUrl = url.toLowerCase();
    
    // Official/Government sources
    if (lowercaseUrl.contains('.gov') || lowercaseUrl.contains('.edu')) {
      return 0.95;
    }
    
    // Major authoritative sources
    final authoritativeDomains = [
      'wikipedia.org', 'britannica.com', 'nature.com', 'science.org',
      'github.com', 'stackoverflow.com', 'developer.mozilla.org',
      'docs.microsoft.com', 'developer.apple.com', 'cloud.google.com',
      'arxiv.org', 'ieee.org', 'acm.org',
    ];
    if (authoritativeDomains.any((d) => lowercaseUrl.contains(d))) {
      return 0.85;
    }
    
    // Major news outlets
    final newsOutlets = [
      'reuters.com', 'apnews.com', 'bbc.com', 'nytimes.com',
      'wsj.com', 'economist.com', 'ft.com',
      'xinhuanet.com', 'people.com.cn', 'chinadaily.com.cn',
    ];
    if (newsOutlets.any((d) => lowercaseUrl.contains(d))) {
      return 0.75;
    }
    
    // Social media / forums (lower reliability)
    final socialPlatforms = [
      'twitter.com', 'x.com', 'facebook.com', 'reddit.com',
      'quora.com', 'zhihu.com', 'weibo.com', 'douban.com',
      'tieba.baidu.com', 'bbs.', 'forum.',
    ];
    if (socialPlatforms.any((d) => lowercaseUrl.contains(d))) {
      return 0.45;
    }
    
    // Blog platforms (medium reliability)
    final blogPlatforms = ['medium.com', 'substack.com', 'wordpress.com', 'blogger.com', 'csdn.net', 'jianshu.com'];
    if (blogPlatforms.any((d) => lowercaseUrl.contains(d))) {
      return 0.55;
    }
    
    // Default: unknown reliability
    return 0.6;
  }
  
  /// Detect authority level based on URL
  String _detectAuthorityLevel(String url) {
    final lowercaseUrl = url.toLowerCase();
    
    if (lowercaseUrl.contains('.gov') || lowercaseUrl.contains('.edu') ||
        lowercaseUrl.contains('official') || lowercaseUrl.contains('docs.')) {
      return 'official';
    }
    
    final authoritativeDomains = [
      'wikipedia.org', 'britannica.com', 'nature.com', 'science.org',
      'github.com', 'stackoverflow.com', 'arxiv.org',
    ];
    if (authoritativeDomains.any((d) => lowercaseUrl.contains(d))) {
      return 'authoritative';
    }
    
    final newsOutlets = [
      'reuters.com', 'apnews.com', 'bbc.com', 'nytimes.com', 'wsj.com',
      'xinhuanet.com', 'people.com.cn', 'thepaper.cn',
    ];
    if (newsOutlets.any((d) => lowercaseUrl.contains(d))) {
      return 'news';
    }
    
    final socialPlatforms = [
      'twitter.com', 'x.com', 'facebook.com', 'instagram.com',
      'weibo.com', 'douyin.com', 'tiktok.com',
    ];
    if (socialPlatforms.any((d) => lowercaseUrl.contains(d))) {
      return 'social';
    }
    
    final forumPlatforms = [
      'reddit.com', 'quora.com', 'zhihu.com', 'tieba.', 'bbs.', 'forum.',
    ];
    if (forumPlatforms.any((d) => lowercaseUrl.contains(d))) {
      return 'forum';
    }
    
    return 'unknown';
  }
  
  /// Parse relative age string to DateTime
  DateTime? _parseRelativeAge(String age) {
    final now = DateTime.now();
    final lowercaseAge = age.toLowerCase();
    
    final dayMatch = RegExp(r'(\d+)\s*day').firstMatch(lowercaseAge);
    if (dayMatch != null) {
      return now.subtract(Duration(days: int.parse(dayMatch.group(1)!)));
    }
    
    final weekMatch = RegExp(r'(\d+)\s*week').firstMatch(lowercaseAge);
    if (weekMatch != null) {
      return now.subtract(Duration(days: int.parse(weekMatch.group(1)!) * 7));
    }
    
    final monthMatch = RegExp(r'(\d+)\s*month').firstMatch(lowercaseAge);
    if (monthMatch != null) {
      return now.subtract(Duration(days: int.parse(monthMatch.group(1)!) * 30));
    }
    
    final yearMatch = RegExp(r'(\d+)\s*year').firstMatch(lowercaseAge);
    if (yearMatch != null) {
      return now.subtract(Duration(days: int.parse(yearMatch.group(1)!) * 365));
    }
    
    if (lowercaseAge.contains('today') || lowercaseAge.contains('hour')) {
      return now;
    }
    
    return null;
  }

  /// Synthesize search results using Worker API to extract global perspective
  /// Returns a synthesized summary ReferenceItem + original refs
  Future<Map<String, dynamic>> synthesizeSearchResults({
    required List<ReferenceItem> refs,
    required String query,
  }) async {
    if (refs.isEmpty) {
      return {'synthesis': null, 'refs': refs};
    }
    
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Helper to check if URL is valid (not placeholder)
      bool isValidUrl(String url) {
        return url.isNotEmpty && 
               !url.contains('your-oneapi-host') && 
               !url.contains('your-api-host');
      }
      
      // Get user's configured chat model as ultimate fallback
      final userChatModel = prefs.getString('chat_model') ?? '';
      final fallbackModel = userChatModel.isNotEmpty ? userChatModel : 'gpt-4o-mini';
      
      // Try Worker config first, then Worker Pro, then fallback to main Chat API
      String workerBaseUrl = prefs.getString('worker_base') ?? '';
      String workerApiKey = '';
      String workerModel = prefs.getString('worker_model') ?? '';
      if (workerModel.isEmpty) workerModel = fallbackModel;
      
      // Parse Worker keys (comma-separated, use first one)
      final workerKeys = prefs.getString('worker_keys') ?? '';
      if (isValidUrl(workerBaseUrl) && workerKeys.isNotEmpty) {
        final keyList = workerKeys.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
        if (keyList.isNotEmpty) {
          workerApiKey = keyList.first;
        }
      }
      
      // Fallback to Worker Pro if Worker not configured
      if (workerBaseUrl.isEmpty || workerApiKey.isEmpty || !isValidUrl(workerBaseUrl)) {
        workerBaseUrl = prefs.getString('worker_pro_base') ?? '';
        final proKeys = prefs.getString('worker_pro_keys') ?? '';
        if (isValidUrl(workerBaseUrl) && proKeys.isNotEmpty) {
          final keyList = proKeys.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
          if (keyList.isNotEmpty) {
            workerApiKey = keyList.first;
          }
        }
        workerModel = prefs.getString('worker_pro_model') ?? '';
        if (workerModel.isEmpty) workerModel = fallbackModel;
      }
      
      // Fallback to Router API
      if (workerBaseUrl.isEmpty || workerApiKey.isEmpty || !isValidUrl(workerBaseUrl)) {
        workerBaseUrl = prefs.getString('router_base') ?? '';
        workerApiKey = prefs.getString('router_key') ?? '';
        workerModel = prefs.getString('router_model') ?? '';
        if (workerModel.isEmpty) workerModel = fallbackModel;
      }
      
      // Final fallback to main Chat API
      if (workerBaseUrl.isEmpty || workerApiKey.isEmpty || !isValidUrl(workerBaseUrl)) {
        workerBaseUrl = prefs.getString('chat_base') ?? '';
        workerApiKey = prefs.getString('chat_key') ?? '';
        workerModel = prefs.getString('chat_model') ?? '';
        if (workerModel.isEmpty) workerModel = fallbackModel;
      }
      
      if (!isValidUrl(workerBaseUrl) || workerApiKey.isEmpty) {
        debugPrint('No API configured for synthesis, skipping');
        return {'synthesis': null, 'refs': refs};
      }
      
      // Normalize base URL - respect user's path configuration
      // User can configure: "https://api.example.com/v1" or "https://api.example.com" or "https://custom.api/path"
      // We only remove trailing slashes and append /chat/completions
      String apiEndpoint = workerBaseUrl.replaceAll(RegExp(r'/+$'), ''); // Remove trailing slashes
      apiEndpoint = '$apiEndpoint/chat/completions';
      
      // Build prompt for Worker to synthesize
      final sourceData = StringBuffer();
      sourceData.writeln('搜索查询: $query\n');
      sourceData.writeln('=== 搜索结果 ===\n');
      
      for (var i = 0; i < refs.length; i++) {
        final ref = refs[i];
        final reliabilityIcon = (ref.reliability ?? 0.5) >= 0.8 ? '🟢' : 
                               ((ref.reliability ?? 0.5) >= 0.6 ? '🟡' : '🔴');
        sourceData.writeln('【来源 ${i + 1}】$reliabilityIcon');
        sourceData.writeln('标题: ${ref.title}');
        sourceData.writeln('URL: ${ref.url}');
        sourceData.writeln('可信度: ${((ref.reliability ?? 0.5) * 100).round()}%');
        sourceData.writeln('权威级别: ${ref.authorityLevel}');
        sourceData.writeln('内容:\n${ref.snippet}\n');
        sourceData.writeln('---\n');
      }
      
      final synthesisPrompt = '''
你是一个信息分析专家。请对以下搜索结果进行综合分析，提取全局视角。

任务：
1. **共识分析**: 识别多个来源一致认同的核心观点
2. **差异对比**: 指出不同来源之间的观点差异或矛盾
3. **可信度评估**: 基于来源权威性评估信息可靠程度
4. **知识盲区**: 识别搜索结果未能覆盖的重要方面
5. **全局总结**: 综合所有信息给出整体结论

${sourceData.toString()}

请用以下JSON格式输出（直接输出JSON，不要markdown代码块）:
{
  "consensus": ["共识点1", "共识点2", ...],
  "divergences": [{"topic": "主题", "viewA": "观点A", "viewB": "观点B", "sources": [1, 3]}],
  "reliability_assessment": "整体可信度评估说明",
  "blind_spots": ["未覆盖方面1", "未覆盖方面2"],
  "global_summary": "全局综合总结（150-300字）",
  "key_facts": ["关键事实1", "关键事实2", ...],
  "confidence_level": 0.0-1.0
}
''';

      final requestBody = json.encode({
        'model': workerModel,
        'messages': [
          {'role': 'system', 'content': '你是信息综合分析专家，擅长从多个来源提取全局视角。'},
          {'role': 'user', 'content': synthesisPrompt}
        ],
        'temperature': 0.3,
        'max_tokens': 8000, // 用户API支持60K tokens
      });

      final uri = Uri.parse(apiEndpoint);
      
      // 使用带重试的请求
      final response = await _httpWithRetry(() => http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $workerApiKey',
          'Content-Type': 'application/json',
        },
        body: requestBody,
      ).timeout(const Duration(seconds: 60)));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final content = data['choices']?[0]?['message']?['content'] ?? '';
        
        // Parse the JSON response
        try {
          // Try to extract JSON from the response (handle potential markdown wrapping)
          String jsonStr = content;
          final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(content);
          if (jsonMatch != null) {
            jsonStr = jsonMatch.group(0)!;
          }
          
          final synthesis = json.decode(jsonStr) as Map<String, dynamic>;
          
          // Create a synthesized reference item
          final globalSummary = synthesis['global_summary'] ?? '';
          final keyFacts = (synthesis['key_facts'] as List?)?.join('；') ?? '';
          final blindSpots = (synthesis['blind_spots'] as List?)?.join('、') ?? '';
          final confidenceLevel = (synthesis['confidence_level'] ?? 0.7) as num;
          
          // Format divergences if any
          final divergences = synthesis['divergences'] as List?;
          String divergenceStr = '';
          if (divergences != null && divergences.isNotEmpty) {
            final divBuffer = StringBuffer();
            divBuffer.writeln('⚠️ **观点分歧**:');
            for (var div in divergences) {
              if (div is Map) {
                divBuffer.writeln('  • ${div['topic'] ?? "?"}: 来源A说"${div['viewA'] ?? "?"}" vs 来源B说"${div['viewB'] ?? "?"}"');
              }
            }
            divergenceStr = divBuffer.toString();
          }
          
          // Format consensus
          final consensus = synthesis['consensus'] as List?;
          String consensusStr = '';
          if (consensus != null && consensus.isNotEmpty) {
            consensusStr = '✅ **多源共识**: ${consensus.join('；')}';
          }
          
          final synthesisSnippet = '''
📊 **全局视角综合**

$globalSummary

🔑 **关键事实**: $keyFacts

$consensusStr

$divergenceStr

${blindSpots.isNotEmpty ? '❓ **知识盲区**: $blindSpots' : ''}

📈 综合置信度: ${(confidenceLevel * 100).round()}%
''';
          
          final synthesizedRef = ReferenceItem(
            title: '🌐 搜索结果全局综合分析',
            url: 'synthesis://global-perspective',
            snippet: synthesisSnippet,
            sourceName: 'AI Synthesis',
            sourceType: 'synthesis',
            reliability: confidenceLevel.toDouble(),
            authorityLevel: 'synthesized',
            contentDate: DateTime.now(),
          );
          
          return {
            'synthesis': synthesizedRef,
            'synthesisData': synthesis,
            'refs': refs,
          };
        } catch (parseError) {
          debugPrint('Failed to parse synthesis JSON: $parseError');
          // Return raw content as synthesis
          final fallbackRef = ReferenceItem(
            title: '🌐 搜索结果综合分析',
            url: 'synthesis://global-perspective',
            snippet: content.length > 4000 ? content.substring(0, 4000) : content,
            sourceName: 'AI Synthesis',
            sourceType: 'synthesis',
            reliability: 0.7,
            authorityLevel: 'synthesized',
            contentDate: DateTime.now(),
          );
          return {
            'synthesis': fallbackRef,
            'refs': refs,
          };
        }
      } else {
        debugPrint('Worker API error: ${response.statusCode}');
        return {'synthesis': null, 'refs': refs};
      }
    } catch (e) {
      debugPrint('Synthesis error: $e');
      return {'synthesis': null, 'refs': refs};
    }
  }

  /// Fetch and extract readable content from a URL
  /// Uses basic HTML parsing to extract main content
  Future<ReferenceItem> fetchUrlContent(String url) async {
    try {
      final uri = Uri.parse(url);
      
      // 使用带重试的请求获取网页内容
      final response = await _httpWithRetry(() => http.get(
        uri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 60)));

      if (response.statusCode == 200) {
        final html = utf8.decode(response.bodyBytes, allowMalformed: true);
        
        // Extract title
        String title = url;
        final titleMatch = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false).firstMatch(html);
        if (titleMatch != null) {
          title = _decodeHtmlEntities(titleMatch.group(1)?.trim() ?? url);
        }
        
        // Remove script, style, nav, footer, header, aside tags
        String cleaned = html
          .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<nav[^>]*>[\s\S]*?</nav>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<footer[^>]*>[\s\S]*?</footer>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<header[^>]*>[\s\S]*?</header>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<aside[^>]*>[\s\S]*?</aside>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<noscript[^>]*>[\s\S]*?</noscript>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<!--[\s\S]*?-->', caseSensitive: false), '');
        
        // Try to find main content areas
        String mainContent = '';
        
        // Priority 1: article tag
        final articleMatch = RegExp(r'<article[^>]*>([\s\S]*?)</article>', caseSensitive: false).firstMatch(cleaned);
        if (articleMatch != null) {
          mainContent = articleMatch.group(1) ?? '';
        }
        
        // Priority 2: main tag
        if (mainContent.isEmpty) {
          final mainMatch = RegExp(r'<main[^>]*>([\s\S]*?)</main>', caseSensitive: false).firstMatch(cleaned);
          if (mainMatch != null) {
            mainContent = mainMatch.group(1) ?? '';
          }
        }
        
        // Priority 3: div with content-related class/id
        if (mainContent.isEmpty) {
          final contentDivMatch = RegExp(
            r'<div[^>]*(?:class|id)=["' "'" r'][^"' "'" r']*(?:content|article|post|entry|main)[^"' "'" r']*["' "'" r'][^>]*>([\s\S]*?)</div>',
            caseSensitive: false
          ).firstMatch(cleaned);
          if (contentDivMatch != null) {
            mainContent = contentDivMatch.group(1) ?? '';
          }
        }
        
        // Priority 4: body content
        if (mainContent.isEmpty) {
          final bodyMatch = RegExp(r'<body[^>]*>([\s\S]*?)</body>', caseSensitive: false).firstMatch(cleaned);
          if (bodyMatch != null) {
            mainContent = bodyMatch.group(1) ?? '';
          }
        }
        
        // Fallback to cleaned HTML
        if (mainContent.isEmpty) {
          mainContent = cleaned;
        }
        
        // Extract text from HTML
        String text = mainContent
          .replaceAll(RegExp(r'<br\s*/?>|<p[^>]*>|</p>|<div[^>]*>|</div>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), '') // Remove all HTML tags
          .replaceAll(RegExp(r'\n\s*\n+'), '\n\n') // Normalize line breaks
          .replaceAll(RegExp(r'[ \t]+'), ' ') // Normalize spaces
          .trim();
        
        // Decode HTML entities
        text = _decodeHtmlEntities(text);
        
        // Limit content length (用户API支持60K tokens)
        if (text.length > 20000) {
          text = '${text.substring(0, 20000)}\n\n[...内容已截断，共${text.length}字符]';
        }
        
        return ReferenceItem(
          title: '📄 $title',
          url: url,
          snippet: text.isNotEmpty ? text : '无法提取网页内容',
          sourceName: uri.host,
          sourceType: 'url_content',
          reliability: _estimateReliability(url),
          authorityLevel: _detectAuthorityLevel(url),
        );
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('fetchUrlContent error for $url: $e');
      return ReferenceItem(
        title: '⚠️ 无法获取网页',
        url: url,
        snippet: '获取网页内容失败: $e',
        sourceName: 'error',
        sourceType: 'url_content',
        reliability: 0.0,
        authorityLevel: 'unknown',
      );
    }
  }
  
  /// Decode common HTML entities
  String _decodeHtmlEntities(String text) {
    return text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&mdash;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll('&hellip;', '...')
      .replaceAll('&copy;', '©')
      .replaceAll('&reg;', '®')
      .replaceAll('&trade;', '™')
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
        final code = int.tryParse(m.group(1) ?? '');
        return code != null ? String.fromCharCode(code) : m.group(0)!;
      })
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m.group(1) ?? '', radix: 16);
        return code != null ? String.fromCharCode(code) : m.group(0)!;
      });
  }

  // Format references for LLM context (if needed)
  String formatForLLM(List<ReferenceItem> refs) {
    if (refs.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('\n【参考资料 (References)】');
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      if (ref.sourceType == 'vision') {
        // Vision analysis result
        buffer.writeln('${i + 1}. [图片分析] ${ref.title}');
        buffer.writeln('   内容: ${ref.snippet}');
      } else if (ref.sourceType == 'generated') {
        // Generated image
        buffer.writeln('${i + 1}. [已生成图片] ${ref.title}');
        buffer.writeln('   描述: ${ref.snippet}');
      } else {
        // Web search result
        buffer.writeln('${i + 1}. ${ref.title} (${ref.sourceName})');
        buffer.writeln('   摘要: ${ref.snippet}');
        buffer.writeln('   链接: ${ref.url}');
      }
    }
    return buffer.toString();
  }

  /// Persist external references (search results, vision results, etc.) into SharedPreferences.
  /// Each entry is stored as a JSON string under key `external_references`.
  Future<void> addExternalReferences(List<ReferenceItem> refs) async {
    if (refs.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList('external_references') ?? [];
    final updated = List<String>.from(existing);
    for (var r in refs) {
      updated.add(json.encode(r.toJson()));
    }
    await prefs.setStringList('external_references', updated);
  }

  /// Retrieve ALL stored references from both session_references and external_references.
  /// Used by deep profiling to get comprehensive user activity history.
  Future<List<ReferenceItem>> getAllStoredReferences() async {
    final prefs = await SharedPreferences.getInstance();
    final List<ReferenceItem> allItems = [];
    
    // Get session references
    final sessionList = prefs.getStringList('session_references') ?? [];
    for (var s in sessionList) {
      try {
        allItems.add(ReferenceItem.fromJson(json.decode(s)));
      } catch (e) {
        // Skip invalid entries
      }
    }
    
    // Get external references
    final externalList = prefs.getStringList('external_references') ?? [];
    for (var s in externalList) {
      try {
        allItems.add(ReferenceItem.fromJson(json.decode(s)));
      } catch (e) {
        // Skip invalid entries
      }
    }
    
    return allItems;
  }

  /// Retrieve persisted external references. Optionally filter by sourceType ('vision', 'web', etc.).
  Future<List<ReferenceItem>> getExternalReferences({String? sourceType}) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('external_references') ?? [];
    final items = list.map((s) {
      try {
        return ReferenceItem.fromJson(json.decode(s));
      } catch (e) {
        return null;
      }
    }).whereType<ReferenceItem>().toList();
    if (sourceType != null) {
      return items.where((i) => i.sourceType == sourceType).toList();
    }
    return items;
  }

  /// Clear all external references
  Future<void> clearExternalReferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('external_references');
  }

  /// Helper to fetch references associated with a given imageId
  Future<List<ReferenceItem>> getReferencesByImageId(String imageId) async {
    if (imageId.isEmpty) return [];
    final all = await getExternalReferences();
    return all.where((r) => r.imageId == imageId).toList();
  }
}
