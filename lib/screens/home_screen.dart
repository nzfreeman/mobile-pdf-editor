import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/recent_files_service.dart';
import 'pdf_editor_screen.dart';
import 'tools_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _recentService = RecentFilesService();
  List<RecentPdfFile> _recentFiles = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final files = await _recentService.load();
    if (mounted) setState(() => _recentFiles = files);
  }

  Future<void> _open(File file, String name) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PdfEditorScreen(pdfFile: file, fileName: name),
      ),
    );
    await _loadRecent();
  }

  Future<void> _pickLocal() async {
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      final path = result?.files.single.path;
      if (path != null) {
        final imported = await _recentService.importFile(
          File(path),
          result!.files.single.name,
        );
        if (mounted) await _open(imported, result.files.single.name);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeRecent(RecentPdfFile recent) async {
    await _recentService.remove(recent.path);
    if (mounted) await _loadRecent();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile PDF Editor'),
        actions: [
          IconButton(
            tooltip: '테마 변경',
            onPressed: () {
              final next = AppSettings.themeMode.value == ThemeMode.dark
                  ? ThemeMode.light
                  : ThemeMode.dark;
              AppSettings.setThemeMode(next);
            },
            icon: const Icon(Icons.dark_mode_outlined),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    children: [
                      Icon(
                        Icons.picture_as_pdf,
                        size: 74,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'PDF 읽기 및 편집',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '텍스트 · 자유 필기 · 서명 · 이미지 · 페이지 관리',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _pickLocal,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('PDF 열기'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ToolsScreen()),
                          ),
                          icon: const Icon(Icons.grid_view_rounded),
                          label: const Text('PDF 도구'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Text(
                    '최근 파일',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  Text('${_recentFiles.length}개'),
                ],
              ),
              const SizedBox(height: 10),
              if (_recentFiles.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('최근에 연 PDF가 없습니다.')),
                  ),
                )
              else
                ..._recentFiles.map(
                  (recent) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
                      title: Text(recent.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: const Text('탭하여 계속 편집'),
                      onTap: () => _open(File(recent.path), recent.name),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'remove') _removeRecent(recent);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'remove',
                            child: Text('최근 목록에서 제거'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.cloud),
                label: const Text('Google Drive 연결 준비 중'),
              ),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x44000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
