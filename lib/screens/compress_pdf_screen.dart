import 'dart:io';

import 'package:flutter/material.dart';

import '../services/android_file_service.dart';
import '../services/pdf_service.dart';

class CompressPdfScreen extends StatefulWidget {
  const CompressPdfScreen({
    super.key,
    required this.file,
    required this.fileName,
  });

  final File file;
  final String fileName;

  @override
  State<CompressPdfScreen> createState() => _CompressPdfScreenState();
}

class _CompressPdfScreenState extends State<CompressPdfScreen> {
  PdfCompressionLevel _level = PdfCompressionLevel.medium;
  bool _busy = false;
  int? _originalSize;

  @override
  void initState() {
    super.initState();
    _originalSize = widget.file.lengthSync();
  }

  Future<void> _compress() async {
    setState(() => _busy = true);
    try {
      final output = await PdfService.compressPdf(
        file: widget.file,
        sourceName: widget.fileName,
        level: _level,
      );
      final compressedSize = await output.length();
      if (!mounted) return;
      final saved = await AndroidFileService.savePdf(
        sourcePath: output.path,
        fileName:
            '${widget.fileName.replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '')}_compressed.pdf',
      );
      if (saved && mounted) {
        final original = _originalSize ?? compressedSize;
        final percent = original == 0
            ? 0
            : (100 - (compressedSize * 100 / original)).round();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF를 저장했습니다. (용량 약 $percent% 감소)')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF 압축 실패: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _label(PdfCompressionLevel level) => switch (level) {
    PdfCompressionLevel.low => '최대 압축 (화질 낮음)',
    PdfCompressionLevel.medium => '보통 압축 (권장)',
    PdfCompressionLevel.high => '약한 압축 (화질 우선)',
  };

  @override
  Widget build(BuildContext context) {
    final originalSize = _originalSize;
    return Scaffold(
      appBar: AppBar(title: const Text('PDF 압축')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                widget.fileName,
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
              if (originalSize != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '원본 크기: ${(originalSize / 1024).toStringAsFixed(0)} KB',
                  ),
                ),
              const SizedBox(height: 16),
              RadioGroup<PdfCompressionLevel>(
                groupValue: _level,
                onChanged: (value) {
                  if (_busy || value == null) return;
                  setState(() => _level = value);
                },
                child: Column(
                  children: [
                    for (final level in PdfCompressionLevel.values)
                      RadioListTile<PdfCompressionLevel>(
                        value: level,
                        title: Text(_label(level)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _compress,
                icon: const Icon(Icons.compress),
                label: const Text('압축 후 저장'),
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
