import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as image_lib;

import '../services/pdf_service.dart';

class OrganizePdfScreen extends StatefulWidget {
  const OrganizePdfScreen({super.key, required this.file, required this.fileName});

  final File file;
  final String fileName;

  @override
  State<OrganizePdfScreen> createState() => _OrganizePdfScreenState();
}

class _OrganizePdfScreenState extends State<OrganizePdfScreen> {
  List<RenderedPdfPage> _pages = [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pages = await PdfService.renderAllPages(widget.file);
      if (mounted) setState(() => _pages = pages);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _delete(int index) {
    if (_pages.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF에는 최소 한 페이지가 필요합니다.')),
      );
      return;
    }
    setState(() => _pages.removeAt(index));
  }

  Future<void> _rotate(int index) async {
    final page = _pages[index];
    final decoded = image_lib.decodeImage(page.bytes);
    if (decoded == null) return;
    final rotated = image_lib.copyRotate(decoded, angle: 90);
    final bytes = image_lib.encodePng(rotated);
    setState(() {
      _pages[index] = RenderedPdfPage(
        bytes: bytes,
        width: page.height,
        height: page.width,
      );
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final output = await PdfService.exportMultiPagePdf(
        pages: _pages,
        items: const [],
        sourceName: widget.fileName,
      );
      final base = widget.fileName.replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      final result = await FilePicker.saveFile(
        dialogTitle: '정리한 PDF 저장',
        fileName: '${base}_organized.pdf',
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        bytes: await output.readAsBytes(),
      );
      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('정리한 PDF를 저장했습니다.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('페이지 구성'),
        actions: [
          IconButton(
            onPressed: _saving || _pages.isEmpty ? null : _save,
            icon: const Icon(Icons.save_outlined),
            tooltip: '저장',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _pages.length,
              onReorderItem: (oldIndex, newIndex) {
                setState(() {
                  final page = _pages.removeAt(oldIndex);
                  _pages.insert(newIndex, page);
                });
              },
              itemBuilder: (context, index) {
                final page = _pages[index];
                return Card(
                  key: ValueKey(page),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                        SizedBox(
                          width: 76,
                          height: 104,
                          child: Image.memory(page.bytes, fit: BoxFit.contain),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '페이지 ${index + 1}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          onPressed: () => _rotate(index),
                          icon: const Icon(Icons.rotate_right),
                          tooltip: '90° 회전',
                        ),
                        IconButton(
                          onPressed: () => _delete(index),
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '삭제',
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
