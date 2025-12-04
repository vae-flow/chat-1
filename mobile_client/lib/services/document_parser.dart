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
      if (name.endsWith('word/document.xml')) {
        documentXml = entry;
        break;
      }
    }

    if (documentXml == null) {
      throw Exception('DOCX 内未找到正文内容');
    }

    final xmlString = utf8.decode(documentXml.content as List<int>);
    final xmlDoc = XmlDocument.parse(xmlString);
    final buffer = StringBuffer();

    for (final node in xmlDoc.findAllElements('t')) {
      buffer.write(node.text);
      buffer.write(' ');
    }

    return _normalizeWhitespace(buffer.toString());
  }

  static String _normalizeWhitespace(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
