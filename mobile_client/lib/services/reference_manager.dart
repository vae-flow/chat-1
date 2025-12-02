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
      throw e; 
    }
  }

  Future<List<ReferenceItem>> _searchExa(String query, String key, String baseUrl) async {
    if (key.isEmpty) throw Exception('Exa Key not configured');
    final uri = Uri.parse('$baseUrl/search');
    final resp = await http.post(
      uri,
      headers: {
        'x-api-key': key,
        'Content-Type': 'application/json',
      },
      body: json.encode({
        'query': query,
        'numResults': 5,
        'useAutoprompt': true,
        'contents': {'text': true} 
      }),
    ).timeout(const Duration(seconds: 15));
    
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

  Future<List<ReferenceItem>> _searchYou(String query, String key, String baseUrl) async {
    if (key.isEmpty) throw Exception('You.com Key not configured');
    
    // Fix: Use 'count' parameter as per documentation
    // Ensure URL handles /v1 if not present in baseUrl, or assume user configures it.
    // We will use the baseUrl as provided, assuming it includes /v1 if needed (updated in Settings).
    final uri = Uri.parse('$baseUrl/search?query=${Uri.encodeComponent(query)}&count=5');
    final resp = await http.get(
      uri,
      headers: {'X-API-Key': key},
    ).timeout(const Duration(seconds: 15));

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

      return hits.map((h) => ReferenceItem(
        title: h['title'] ?? h['name'] ?? 'No Title',
        url: h['url'] ?? h['link'] ?? '',
        snippet: (h['snippets'] as List?)?.join(' ') ?? h['description'] ?? h['snippet'] ?? h['text'] ?? '',
        sourceName: 'You.com',
      )).toList();
    }
    // Add more detailed error logging
    debugPrint('You.com Error Body: ${resp.body}');
    throw Exception('You.com API Error: ${resp.statusCode} - ${resp.body}');
  }

  Future<List<ReferenceItem>> _searchBrave(String query, String key, String baseUrl) async {
    if (key.isEmpty) throw Exception('Brave Key not configured');
    final uri = Uri.parse('$baseUrl/res/v1/web/search?q=${Uri.encodeComponent(query)}&count=5');
    final resp = await http.get(
      uri,
      headers: {
        'X-Subscription-Token': key,
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: 15));

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
      
      return results.map((r) => ReferenceItem(
        title: r['title'] ?? 'No Title',
        url: r['url'] ?? '',
        snippet: r['description'] ?? r['snippet'] ?? '',
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
