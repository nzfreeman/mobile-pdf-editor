import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/ocr_service.dart';
import '../services/pdf_service.dart';

class OcrScreen extends StatefulWidget {
  const OcrScreen({super.key, required this.pdfFile, required this.fileName});

  final File pdfFile;
  final String fileName;

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen> {
  bool _loading = true;
  String? _error;
  final List<String> _pageTexts = [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final pages = await PdfService.renderAllPages(widget.pdfFile);
      final texts = <String>[];
      for (final page in pages) {
        final blocks = await OcrService.recognizeText(page.bytes);
        texts.add(blocks.map((block) => block.text).join('\n'));
      }
      if (mounted) setState(() => _pageTexts.addAll(texts));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _fullText => _pageTexts
      .asMap()
      .entries
      .map((entry) => '--- ${entry.key + 1} 페이지 ---\n${entry.value}')
      .join('\n\n');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('OCR · ${widget.fileName}', overflow: TextOverflow.ellipsis),
        actions: [
          if (!_loading && _error == null)
            IconButton(
              tooltip: '텍스트 복사',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: _fullText));
                messenger.showSnackBar(
                  const SnackBar(content: Text('인식된 텍스트를 복사했습니다.')),
                );
              },
            ),
          if (!_loading && _error == null)
            IconButton(
              tooltip: '공유',
              icon: const Icon(Icons.share_outlined),
              onPressed: () => SharePlus.instance.share(
                ShareParams(text: _fullText, subject: '${widget.fileName} OCR'),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('텍스트 인식 실패: $_error'))
          : _pageTexts.every((text) => text.trim().isEmpty)
          ? const Center(child: Text('인식된 텍스트가 없습니다.'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _pageTexts.length,
              separatorBuilder: (_, _) => const Divider(height: 32),
              itemBuilder: (_, index) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${index + 1} 페이지',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    _pageTexts[index].trim().isEmpty
                        ? '(인식된 텍스트 없음)'
                        : _pageTexts[index],
                  ),
                ],
              ),
            ),
    );
  }
}
