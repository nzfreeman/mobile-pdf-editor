import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecentPdfFile {
  const RecentPdfFile({required this.name, required this.path});

  final String name;
  final String path;
}

class RecentFilesService {
  static const _key = 'recent_pdf_paths';

  Future<List<RecentPdfFile>> load() async {
    final preferences = SharedPreferencesAsync();
    final paths = await preferences.getStringList(_key) ?? const <String>[];
    final result = <RecentPdfFile>[];
    for (final path in paths) {
      final file = File(path);
      if (await file.exists()) {
        result.add(RecentPdfFile(name: file.uri.pathSegments.last, path: path));
      }
    }
    if (result.length != paths.length) {
      await preferences.setStringList(_key, result.map((file) => file.path).toList());
    }
    return result;
  }

  Future<File> importFile(File source, String originalName) async {
    final directory = await getApplicationDocumentsDirectory();
    final recentDirectory = Directory('${directory.path}/recent_pdfs');
    await recentDirectory.create(recursive: true);
    final safeName = originalName.replaceAll(RegExp(r'[^a-zA-Z0-9가-힣._-]'), '_');
    final target = File(
      '${recentDirectory.path}/${DateTime.now().millisecondsSinceEpoch}_$safeName',
    );
    await source.copy(target.path);
    await add(target.path);
    return target;
  }

  Future<void> add(String path) async {
    final preferences = SharedPreferencesAsync();
    final paths = await preferences.getStringList(_key) ?? <String>[];
    paths.remove(path);
    paths.insert(0, path);
    if (paths.length > 20) paths.removeRange(20, paths.length);
    await preferences.setStringList(_key, paths);
  }

  Future<void> remove(String path) async {
    final preferences = SharedPreferencesAsync();
    final paths = await preferences.getStringList(_key) ?? <String>[];
    paths.remove(path);
    await preferences.setStringList(_key, paths);
  }
}
