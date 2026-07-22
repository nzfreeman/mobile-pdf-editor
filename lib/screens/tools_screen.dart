import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart';

import '../services/app_settings.dart';
import '../services/image_pdf_service.dart';
import 'organize_pdf_screen.dart';
import 'pdf_editor_screen.dart';

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  final _picker = ImagePicker();
  bool _busy = false;

  Future<File?> _pickPdf() async {
    // File picker functionality removed (file_picker dependency removed)
    // TODO: Implement alternative file selection mechanism
    return null;
    // final result = await FilePicker.pickFiles(
    //   type: FileType.custom,
    //   allowedExtensions: const ['pdf'],
    // );
    // final path = result?.files.single.path;
    // return path == null ? null : File(path);
  }

  Future<void> _imageToPdf() async {
    setState(() => _busy = true);
    try {
      final images = await _picker.pickMultiImage(imageQuality: 94);
      if (images.isEmpty) return;
      final pdf = await ImagePdfService.createPdf(
        images.map((image) => File(image.path)).toList(),
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PdfEditorScreen(
            pdfFile: pdf,
            fileName: 'images.pdf',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanToPdf() async {
    setState(() => _busy = true);
    try {
      final captured = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 95,
      );
      if (captured == null) return;
      final cropped = await ImageCropper().cropImage(
        sourcePath: captured.path,
        compressQuality: 94,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '문서 자르기',
            lockAspectRatio: false,
          ),
        ],
      );
      if (cropped == null) return;
      final pdf = await ImagePdfService.createPdf([File(cropped.path)]);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PdfEditorScreen(
            pdfFile: pdf,
            fileName: 'scan.pdf',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _organize() async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OrganizePdfScreen(
          file: file,
          fileName: file.uri.pathSegments.last,
        ),
      ),
    );
  }

  Future<void> _printPdf() async {
    final file = await _pickPdf();
    if (file == null) return;
    await Printing.layoutPdf(onLayout: (_) => file.readAsBytes());
  }

  void _comingSoon(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name 기능은 다음 단계에서 추가됩니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tools = <_ToolData>[
      _ToolData('이미지 → PDF', Icons.photo_library_outlined, _imageToPdf),
      _ToolData('문서 스캔', Icons.document_scanner_outlined, _scanToPdf),
      _ToolData('페이지 구성', Icons.grid_view_rounded, _organize),
      _ToolData('PDF 편집', Icons.edit_document, () async {
        final file = await _pickPdf();
        if (file == null || !mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PdfEditorScreen(
              pdfFile: file,
              fileName: file.uri.pathSegments.last,
            ),
          ),
        );
      }),
      _ToolData('인쇄', Icons.print_outlined, _printPdf),
      _ToolData('다크 모드', Icons.dark_mode_outlined, () async {
        final next = AppSettings.themeMode.value == ThemeMode.dark
            ? ThemeMode.light
            : ThemeMode.dark;
        await AppSettings.setThemeMode(next);
      }),
      _ToolData('PDF 병합', Icons.call_merge, () => _comingSoon('PDF 병합')),
      _ToolData('PDF 분할', Icons.call_split, () => _comingSoon('PDF 분할')),
      _ToolData('PDF 압축', Icons.compress, () => _comingSoon('PDF 압축')),
      _ToolData('PDF 잠금', Icons.lock_outline, () => _comingSoon('PDF 잠금')),
      _ToolData('잠금 해제', Icons.lock_open, () => _comingSoon('잠금 해제')),
      _ToolData('OCR', Icons.text_snippet_outlined, () => _comingSoon('OCR')),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('PDF 도구')),
      body: Stack(
        children: [
          GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.9,
            ),
            itemCount: tools.length,
            itemBuilder: (_, index) {
              final tool = tools[index];
              return InkWell(
                onTap: _busy ? null : tool.onTap,
                borderRadius: BorderRadius.circular(18),
                child: Card(
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 25,
                          child: Icon(tool.icon, size: 27),
                        ),
                        const SizedBox(height: 10),
                        Text(tool.title, textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              );
            },
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

class _ToolData {
  const _ToolData(this.title, this.icon, this.onTap);

  final String title;
  final IconData icon;
  final VoidCallback onTap;
}
