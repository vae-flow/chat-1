import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';

class FileSaver {
  /// Saves text content to a file using the system file picker.
  /// Returns the path of the saved file or null if cancelled/failed.
  static Future<String?> saveTextFile(String filename, String content) async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/$filename');
      await file.writeAsString(content);

      final params = SaveFileDialogParams(sourceFilePath: file.path);
      final filePath = await FlutterFileDialog.saveFile(params: params);
      
      // Clean up temp file
      if (await file.exists()) {
        await file.delete();
      }
      
      return filePath;
    } catch (e) {
      print('Error saving text file: $e');
      return null;
    }
  }

  /// Saves binary content (e.g., images) to a file using the system file picker.
  static Future<String?> saveBinaryFile(String filename, Uint8List bytes) async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/$filename');
      await file.writeAsBytes(bytes);

      final params = SaveFileDialogParams(sourceFilePath: file.path);
      final filePath = await FlutterFileDialog.saveFile(params: params);

      // Clean up temp file
      if (await file.exists()) {
        await file.delete();
      }

      return filePath;
    } catch (e) {
      print('Error saving binary file: $e');
      return null;
    }
  }
}
