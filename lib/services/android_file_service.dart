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

  static Future<SelectedPdfFile?> pickText() async {
    final result = await _channel.invokeMapMethod<String, String>('pickText');
    if (result == null) return null;
    final path = result['path'];
    final name = result['name'];
    if (path == null || name == null) return null;
    return SelectedPdfFile(path: path, name: name);
  }

  static Future<List<SelectedPdfFile>> pickMultiplePdfs() async {
    final result = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'pickMultiplePdfs',
    );
    if (result == null) return [];
    return result
        .map((entry) {
          final path = entry['path'] as String?;
          final name = entry['name'] as String?;
          if (path == null || name == null) return null;
          return SelectedPdfFile(path: path, name: name);
        })
        .whereType<SelectedPdfFile>()
        .toList();
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
