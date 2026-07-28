import 'dart:io';

import 'package:flutter/material.dart';

import '../services/android_file_service.dart';
import '../services/pdf_service.dart';

class MergePdfScreen extends StatefulWidget {
  const MergePdfScreen({super.key, required this.initialFiles});

  final List<SelectedPdfFile> initialFiles;

  @override
  State<MergePdfScreen> createState() => _MergePdfScreenState();
}

class _MergePdfScreenState extends State<MergePdfScreen> {
  late final List<SelectedPdfFile> _files = List.of(widget.initialFiles);
  bool _busy = false;

  Future<void> _addMore() async {
    final picked = await AndroidFileService.pickMultiplePdfs();
    if (picked.isEmpty) return;
    setState(() => _files.addAll(picked));
  }

  void _remove(int index) => setState(() => _files.removeAt(index));

  Future<void> _merge() async {
    if (_files.length < 2) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('병합하려면 2개 이상의 PDF가 필요합니다.')));
      return;
    }
    setState(() => _busy = true);
    try {
      final output = await PdfService.mergePdfFiles(
        files: _files.map((file) => File(file.path)).toList(),
        sourceName: 'merged.pdf',
      );
      final saved = await AndroidFileService.savePdf(
        sourcePath: output.path,
        fileName: 'merged_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      if (saved && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('병합한 PDF를 저장했습니다.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF 병합 실패: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF 병합'),
        actions: [
          IconButton(
            tooltip: '병합 실행',
            onPressed: _busy ? null : _merge,
            icon: const Icon(Icons.call_merge),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: _files.isEmpty
                    ? const Center(child: Text('병합할 PDF를 추가하세요.'))
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _files.length,
                        onReorderItem: (oldIndex, newIndex) {
                          setState(() {
                            final file = _files.removeAt(oldIndex);
                            _files.insert(newIndex, file);
                          });
                        },
                        itemBuilder: (context, index) {
                          final file = _files[index];
                          return Card(
                            key: ValueKey('${file.path}_$index'),
                            child: ListTile(
                              leading: const Icon(Icons.picture_as_pdf),
                              title: Text(
                                file.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text('${index + 1}번째'),
                              trailing: IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () => _remove(index),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _addMore,
                  icon: const Icon(Icons.add),
                  label: const Text('PDF 추가'),
                ),
              ),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x55000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
