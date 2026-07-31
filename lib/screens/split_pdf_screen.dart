import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/pdf_native/pdf_merge_split_service.dart';
import '../services/pdf_service.dart';

class SplitPdfScreen extends StatefulWidget {
  const SplitPdfScreen({super.key, required this.file, required this.fileName});

  final File file;
  final String fileName;

  @override
  State<SplitPdfScreen> createState() => _SplitPdfScreenState();
}

class _SplitPdfScreenState extends State<SplitPdfScreen> {
  List<RenderedPdfPage> _pages = [];
  final Set<int> _splitAfter = {};
  bool _loading = true;
  bool _busy = false;

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

  List<List<int>> get _groups {
    final groups = <List<int>>[];
    var current = <int>[];
    for (var i = 0; i < _pages.length; i++) {
      current.add(i);
      if (_splitAfter.contains(i)) {
        groups.add(current);
        current = [];
      }
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  Future<void> _split() async {
    final groups = _groups;
    if (groups.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('페이지 사이를 눌러 분할 지점을 추가하세요.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final outputs = await PdfMergeSplitService.split(
        file: widget.file,
        pageGroups: groups,
        sourceName: widget.fileName,
      );
      await SharePlus.instance.share(
        ShareParams(
          files: outputs.map((file) => XFile(file.path)).toList(),
          subject: '${widget.fileName} 분할 결과',
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF 분할 실패: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF 분할'),
        actions: [
          IconButton(
            tooltip: '분할 후 공유',
            onPressed: _busy || _pages.isEmpty ? null : _split,
            icon: const Icon(Icons.call_split),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('나눌 위치를 눌러 분할 지점을 표시하세요.'),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: _pages.length,
                        itemBuilder: (context, index) {
                          final isLast = index == _pages.length - 1;
                          final splitHere = _splitAfter.contains(index);
                          return Column(
                            children: [
                              Card(
                                child: ListTile(
                                  leading: SizedBox(
                                    width: 48,
                                    height: 64,
                                    child: Image.memory(
                                      _pages[index].bytes,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                  title: Text('페이지 ${index + 1}'),
                                ),
                              ),
                              if (!isLast)
                                InkWell(
                                  onTap: () => setState(() {
                                    if (!_splitAfter.add(index)) {
                                      _splitAfter.remove(index);
                                    }
                                  }),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Divider(
                                            color: splitHere
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.primary
                                                : null,
                                            thickness: splitHere ? 2 : 1,
                                          ),
                                        ),
                                        Icon(
                                          splitHere
                                              ? Icons.content_cut
                                              : Icons.add,
                                          size: 18,
                                          color: splitHere
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.primary
                                              : Colors.grey,
                                        ),
                                        Expanded(
                                          child: Divider(
                                            color: splitHere
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.primary
                                                : null,
                                            thickness: splitHere ? 2 : 1,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
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
