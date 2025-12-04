import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

/// Utility to convert various document formats into plain text for ingestion.
class DocumentParser {
  static Future<String> readText(File file, {String? extension}) async {
    final ext = (extension ?? file.path.split('.').last).toLowerCase();
    switch (ext) {
      case 'pdf':
        return _extractPdf(file);
      case 'docx':
        return _extractDocx(file);
      default:
        return _readTextWithFallback(file);
    }
  }

  static Future<String> _readTextWithFallback(File file) async {
    try {
      return await file.readAsString(encoding: utf8);
    } catch (_) {
      final bytes = await file.readAsBytes();
      return const Latin1Decoder().convert(bytes);
    }
  }

  static Future<String> _extractPdf(File file) async {
    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    final extractor = PdfTextExtractor(document);
    final buffer = StringBuffer();

    for (int i = 0; i < document.pages.count; i++) {
      final pageText = extractor.extractText(
        startPageIndex: i,
        endPageIndex: i,
      );
      if (pageText.trim().isNotEmpty) {
        buffer.writeln(pageText.trim());
      }
    }

    document.dispose();
    return _normalizeWhitespace(buffer.toString());
  }

  static Future<String> _extractDocx(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    ArchiveFile? documentXml;

    for (final entry in archive) {
      final name = entry.name.toLowerCase();
      // 兼容不同路径格式
      if (name == 'word/document.xml' || name.endsWith('/word/document.xml')) {
        documentXml = entry;
        break;
      }
    }

    if (documentXml == null) {
      // 尝试列出所有文件帮助调试
      final allFiles = archive.map((e) => e.name).join(', ');
      throw Exception('DOCX 内未找到正文内容。文件列表: $allFiles');
    }

    final xmlString = utf8.decode(documentXml.content as List<int>);
    final xmlDoc = XmlDocument.parse(xmlString);
    final buffer = StringBuffer();

    // 使用多种方式提取文本，兼容不同命名空间
    // 方式1: 直接查找 <w:t> 元素 (带命名空间前缀)
    for (final node in xmlDoc.findAllElements('w:t')) {
      buffer.write(node.innerText);
      buffer.write(' ');
    }
    
    // 方式2: 如果上面没找到，尝试不带前缀的 <t> 元素
    if (buffer.isEmpty) {
      for (final node in xmlDoc.findAllElements('t')) {
        buffer.write(node.innerText);
        buffer.write(' ');
      }
    }
    
    // 方式3: 遍历所有文本节点
    if (buffer.isEmpty) {
      void extractText(XmlNode node) {
        if (node is XmlText) {
          final text = node.value.trim();
          if (text.isNotEmpty) {
            buffer.write(text);
            buffer.write(' ');
          }
        }
        if (node is XmlElement) {
          for (final child in node.children) {
            extractText(child);
          }
        }
      }
      extractText(xmlDoc.rootElement);
    }

    final result = _normalizeWhitespace(buffer.toString());
    if (result.isEmpty) {
      throw Exception('DOCX 解析成功但未提取到文本内容');
    }
    return result;
  }

  static String _normalizeWhitespace(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
