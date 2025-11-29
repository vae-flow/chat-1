import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reference_item.dart';

/// Manages search references and formatting
class ReferenceManager {
  
  Future<List<ReferenceItem>> search(String query) async {
    final prefs = await SharedPreferences.getInstance();
    var provider = prefs.getString('search_provider') ?? 'auto';
    final exaKey = prefs.getString('exa_key') ?? '';
    final youKey = prefs.getString('you_key') ?? '';
    final braveKey = prefs.getString('brave_key') ?? '';

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
          return _searchExa(query, exaKey);
        case 'you':
          return _searchYou(query, youKey);
        case 'brave':
          return _searchBrave(query, braveKey);
        default:
           throw Exception('未知的搜索提供商: $provider');
      }
    } catch (e) {
      debugPrint('Search error ($provider): $e');
      // Re-throw to let the UI handle it or show error
      throw e; 
    }
  }

  Future<List<ReferenceItem>> _searchExa(String query, String key) async {
    if (key.isEmpty) throw Exception('Exa Key not configured');
    final uri = Uri.parse('https://api.exa.ai/search');
    final resp = await http.post(
      uri,
      headers: {
        'x-api-key': key,
        'Content-Type': 'application/json',
      },
      body: json.encode({
        'query': query,
        'numResults': 3,
        'useAutoprompt': true,
        'contents': {'text': true} 
      }),
    );
    
    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final results = data['results'] as List;
      return results.map((r) => ReferenceItem(
        title: r['title'] ?? 'No Title',
        url: r['url'] ?? '',
        snippet: r['text'] != null ? (r['text'] as String).substring(0, (r['text'] as String).length.clamp(0, 300)).replaceAll('\n', ' ') : '',
        sourceName: 'Exa.ai',
      )).toList();
    }
    throw Exception('Exa API Error: ${resp.statusCode}');
  }

  Future<List<ReferenceItem>> _searchYou(String query, String key) async {
    if (key.isEmpty) throw Exception('You.com Key not configured');
    // Updated endpoint to ensure compatibility
    final uri = Uri.parse('https://api.ydc-index.io/search?query=${Uri.encodeComponent(query)}&num_web_results=3');
    final resp = await http.get(
      uri,
      headers: {'X-API-Key': key},
    );

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final hits = data['hits'] as List;
      return hits.map((h) => ReferenceItem(
        title: h['title'] ?? 'No Title',
        url: h['url'] ?? '',
        snippet: (h['snippets'] as List?)?.join(' ') ?? h['description'] ?? '',
        sourceName: 'You.com',
      )).toList();
    }
    // Add more detailed error logging
    debugPrint('You.com Error Body: ${resp.body}');
    throw Exception('You.com API Error: ${resp.statusCode} - ${resp.body}');
  }

  Future<List<ReferenceItem>> _searchBrave(String query, String key) async {
    if (key.isEmpty) throw Exception('Brave Key not configured');
    final uri = Uri.parse('https://api.search.brave.com/res/v1/web/search?q=${Uri.encodeComponent(query)}&count=3');
    final resp = await http.get(
      uri,
      headers: {
        'X-Subscription-Token': key,
        'Accept': 'application/json',
      },
    );

    if (resp.statusCode == 200) {
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final results = data['web']['results'] as List;
      return results.map((r) => ReferenceItem(
        title: r['title'] ?? 'No Title',
        url: r['url'] ?? '',
        snippet: r['description'] ?? '',
        sourceName: 'Brave',
      )).toList();
    }
    // Add more detailed error logging
    debugPrint('Brave Error Body: ${resp.body}');
    throw Exception('Brave API Error: ${resp.statusCode} - ${resp.body}');
  }

  // Format references for LLM context (if needed)
  String formatForLLM(List<ReferenceItem> refs) {
    if (refs.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('\n【参考资料 (References)】');
    for (var i = 0; i < refs.length; i++) {
      buffer.writeln('${i + 1}. ${refs[i].title} (${refs[i].sourceName})');
      buffer.writeln('   摘要: ${refs[i].snippet}');
      buffer.writeln('   链接: ${refs[i].url}');
    }
    return buffer.toString();
  }
}
