import 'dart:io';

import 'package:flutter/material.dart';

import '../services/android_file_service.dart';
import '../services/app_settings.dart';
import '../services/app_update_service.dart';
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
  final _updateService = AppUpdateService();
  List<RecentPdfFile> _recentFiles = [];
  bool _busy = false;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    WidgetsBinding.instance.addPostFrameCallback((_) => _silentUpdateCheck());
  }

  Future<void> _loadRecent() async {
    final files = await _recentService.load();
    if (mounted) setState(() => _recentFiles = files);
  }

  Future<void> _silentUpdateCheck() async {
    final state = await _updateService.check();
    if (!mounted || state.status != AppUpdateStatus.available) return;
    await _showUpdateSheet(initialState: state);
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final state = await _updateService.check();
    if (mounted) {
      setState(() => _checkingUpdate = false);
      await _showUpdateSheet(initialState: state);
    }
  }

  Future<void> _showUpdateSheet({required AppUpdateState initialState}) async {
    var state = initialState;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> run(Future<AppUpdateState> Function() action) async {
            setSheetState(() {
              state = AppUpdateState(
                status: AppUpdateStatus.downloading,
                source: state.source,
                currentVersion: state.currentVersion,
                latestVersion: state.latestVersion,
                message: '업데이트 작업을 진행하고 있습니다…',
              );
            });
            final next = await action();
            if (sheetContext.mounted) setSheetState(() => state = next);
          }

          Future<void> openGitHubDownload() async {
            final opened = await _updateService.openGitHubDownload(state);
            if (!opened && sheetContext.mounted) {
              setSheetState(() {
                state = AppUpdateState(
                  status: AppUpdateStatus.failed,
                  source: AppUpdateSource.github,
                  currentVersion: state.currentVersion,
                  latestVersion: state.latestVersion,
                  message: 'APK 다운로드 페이지를 열지 못했습니다.',
                );
              });
            }
          }

          final available = state.status == AppUpdateStatus.available;
          final ready = state.status == AppUpdateStatus.readyToInstall;
          final github = state.source == AppUpdateSource.github;
          final play = state.source == AppUpdateSource.googlePlay;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        available ? Icons.system_update : Icons.info_outline,
                        size: 32,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '앱 업데이트',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (state.currentVersion != null)
                    Text('현재 버전: ${state.currentVersion}'),
                  if (state.latestVersion != null)
                    Text('최신 버전: ${state.latestVersion}'),
                  if (state.availableVersionCode != null)
                    Text('새 버전 코드: ${state.availableVersionCode}'),
                  if (state.source != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      state.source == AppUpdateSource.googlePlay
                          ? '업데이트 경로: Google Play'
                          : '업데이트 경로: GitHub Releases',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(state.message ?? _updateStatusText(state.status)),
                  if (github && state.releaseNotes != null) ...[
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 140),
                      child: SingleChildScrollView(
                        child: Text(
                          state.releaseNotes!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                  if (state.status == AppUpdateStatus.downloading) ...[
                    const SizedBox(height: 18),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: 20),
                  if (available && github)
                    FilledButton.icon(
                      onPressed: openGitHubDownload,
                      icon: const Icon(Icons.download),
                      label: const Text('새 APK 다운로드'),
                    ),
                  if (available && play && state.flexibleAllowed)
                    FilledButton.icon(
                      onPressed: () => run(_updateService.startFlexible),
                      icon: const Icon(Icons.download),
                      label: const Text('백그라운드 업데이트'),
                    ),
                  if (available && play && state.immediateAllowed) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => run(_updateService.startImmediate),
                      icon: const Icon(Icons.priority_high),
                      label: const Text('지금 바로 업데이트'),
                    ),
                  ],
                  if (ready)
                    FilledButton.icon(
                      onPressed: () => run(_updateService.completeFlexible),
                      icon: const Icon(Icons.install_mobile),
                      label: const Text('다운로드한 업데이트 설치'),
                    ),
                  if (!available && !ready)
                    OutlinedButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('확인'),
                    ),
                  if (available) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('나중에'),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _updateStatusText(AppUpdateStatus status) {
    return switch (status) {
      AppUpdateStatus.checking => '업데이트를 확인하고 있습니다.',
      AppUpdateStatus.unsupported => '이 기기에서는 지원되지 않습니다.',
      AppUpdateStatus.upToDate => '현재 최신 버전을 사용하고 있습니다.',
      AppUpdateStatus.available => '새 업데이트가 있습니다.',
      AppUpdateStatus.downloading => '업데이트를 처리하고 있습니다.',
      AppUpdateStatus.readyToInstall => '업데이트 설치 준비가 완료되었습니다.',
      AppUpdateStatus.completed => '업데이트가 완료되었습니다.',
      AppUpdateStatus.cancelled => '업데이트가 취소되었습니다.',
      AppUpdateStatus.failed => '업데이트 처리 중 오류가 발생했습니다.',
    };
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
      final selected = await AndroidFileService.pickPdf();
      if (selected == null) return;

      final imported = await _recentService.importFile(
        File(selected.path),
        selected.name,
      );
      if (mounted) await _open(imported, selected.name);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF 열기 실패: $error')));
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
            tooltip: '업데이트 확인',
            onPressed: _checkingUpdate ? null : _checkForUpdate,
            icon: _checkingUpdate
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.system_update_alt),
          ),
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
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.5,
                children: [
                  _HomeCategoryTile(
                    icon: Icons.add_box_outlined,
                    label: '새로 만들기',
                    subtitle: '이미지·텍스트·스캔 → PDF',
                    onTap: _busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ToolsScreen(
                                initialCategory: ToolsCategory.create,
                              ),
                            ),
                          ),
                  ),
                  _HomeCategoryTile(
                    icon: Icons.folder_open,
                    label: '불러오기',
                    subtitle: '기기에서 PDF 열기',
                    onTap: _busy ? null : _pickLocal,
                  ),
                  _HomeCategoryTile(
                    icon: Icons.edit_document,
                    label: '편집하기',
                    subtitle: '텍스트·삽입·되돌리기',
                    onTap: _busy
                        ? null
                        : () async {
                            final selected = await AndroidFileService.pickPdf();
                            if (selected == null || !mounted) return;
                            await _open(File(selected.path), selected.name);
                          },
                  ),
                  _HomeCategoryTile(
                    icon: Icons.grid_view_rounded,
                    label: '문서 도구',
                    subtitle: '분할·병합·압축·OCR 등',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ToolsScreen()),
                    ),
                  ),
                ],
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
                      leading: const Icon(
                        Icons.picture_as_pdf,
                        color: Colors.red,
                      ),
                      title: Text(
                        recent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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

class _HomeCategoryTile extends StatelessWidget {
  const _HomeCategoryTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: scheme.primary),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
