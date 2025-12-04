import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';

/// 文件保存模式
enum SaveMode {
  /// 静默保存到 App 目录（不弹窗）
  silent,
  /// 弹出系统文件选择器（需用户确认）
  dialog,
}

class FileSaver {
  /// App 专用文档目录名
  static const String _appFolderName = 'AiCai';
  
  /// 获取 App 专用保存目录
  static Future<Directory> getAppSaveDirectory() async {
    // 优先使用外部存储的 Documents 目录
    Directory? baseDir;
    try {
      baseDir = await getExternalStorageDirectory();
    } catch (_) {}
    
    // 回退到应用文档目录
    baseDir ??= await getApplicationDocumentsDirectory();
    
    // 创建 AiCai 子目录
    final appDir = Directory('${baseDir.path}/$_appFolderName');
    if (!await appDir.exists()) {
      await appDir.create(recursive: true);
    }
    return appDir;
  }

  /// Saves text content to a file.
  /// [mode]: SaveMode.silent (default) - 静默保存; SaveMode.dialog - 弹出选择器
  /// Returns the path of the saved file or null if cancelled/failed.
  static Future<String?> saveTextFile(String filename, String content, {SaveMode mode = SaveMode.silent}) async {
    try {
      if (mode == SaveMode.silent) {
        // 静默保存到 App 目录
        final appDir = await getAppSaveDirectory();
        final file = File('${appDir.path}/$filename');
        
        // 如果文件已存在，添加时间戳避免覆盖
        File targetFile = file;
        if (await file.exists()) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final ext = filename.contains('.') ? '.${filename.split('.').last}' : '';
          final baseName = filename.contains('.') ? filename.substring(0, filename.lastIndexOf('.')) : filename;
          targetFile = File('${appDir.path}/${baseName}_$timestamp$ext');
        }
        
        await targetFile.writeAsString(content);
        return targetFile.path;
      } else {
        // 弹出系统文件选择器
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
      }
    } catch (e) {
      print('Error saving text file: $e');
      return null;
    }
  }

  /// Saves binary content (e.g., images) to a file.
  /// [mode]: SaveMode.silent (default) - 静默保存; SaveMode.dialog - 弹出选择器
  static Future<String?> saveBinaryFile(String filename, Uint8List bytes, {SaveMode mode = SaveMode.silent}) async {
    try {
      if (mode == SaveMode.silent) {
        // 静默保存到 App 目录
        final appDir = await getAppSaveDirectory();
        final file = File('${appDir.path}/$filename');
        
        // 如果文件已存在，添加时间戳避免覆盖
        File targetFile = file;
        if (await file.exists()) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final ext = filename.contains('.') ? '.${filename.split('.').last}' : '';
          final baseName = filename.contains('.') ? filename.substring(0, filename.lastIndexOf('.')) : filename;
          targetFile = File('${appDir.path}/${baseName}_$timestamp$ext');
        }
        
        await targetFile.writeAsBytes(bytes);
        return targetFile.path;
      } else {
        // 弹出系统文件选择器
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
      }
    } catch (e) {
      print('Error saving binary file: $e');
      return null;
    }
  }
  
  /// 列出 App 目录下的所有文件
  static Future<List<FileSystemEntity>> listSavedFiles() async {
    try {
      final appDir = await getAppSaveDirectory();
      return appDir.listSync();
    } catch (e) {
      print('Error listing files: $e');
      return [];
    }
  }
  
  /// 删除 App 目录下的指定文件
  static Future<bool> deleteFile(String filename) async {
    try {
      final appDir = await getAppSaveDirectory();
      final file = File('${appDir.path}/$filename');
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      print('Error deleting file: $e');
      return false;
    }
  }
}
