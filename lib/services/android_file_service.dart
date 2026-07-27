import 'package:flutter/services.dart';

class SelectedPdfFile {
  const SelectedPdfFile({required this.path, required this.name});

  final String path;
  final String name;
}

class AndroidFileService {
  AndroidFileService._();

  static const _channel = MethodChannel('mobile_pdf_editor/file_io');

  static Future<SelectedPdfFile?> pickPdf() async {
    final result = await _channel.invokeMapMethod<String, String>('pickPdf');
    if (result == null) return null;
    final path = result['path'];
    final name = result['name'];
    if (path == null || name == null) return null;
    return SelectedPdfFile(path: path, name: name);
  }

  static Future<bool> savePdf({
    required String sourcePath,
    required String fileName,
  }) async {
    return await _channel.invokeMethod<bool>('savePdf', {
          'sourcePath': sourcePath,
          'fileName': fileName,
        }) ??
        false;
  }
}
