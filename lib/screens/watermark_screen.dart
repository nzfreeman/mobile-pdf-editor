import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/android_file_service.dart';
import '../services/pdf_service.dart';

enum _WatermarkKind { text, image }

class WatermarkScreen extends StatefulWidget {
  const WatermarkScreen({super.key, required this.file, required this.fileName});

  final File file;
  final String fileName;

  @override
  State<WatermarkScreen> createState() => _WatermarkScreenState();
}

class _WatermarkScreenState extends State<WatermarkScreen> {
  final _textController = TextEditingController(text: '기밀 문서');
  _WatermarkKind _kind = _WatermarkKind.text;
  Uint8List? _imageBytes;
  double _opacity = 0.3;
  double _rotation = -45;
  bool _tile = true;
  bool _busy = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => _imageBytes = bytes);
  }

  Future<void> _apply() async {
    if (_kind == _WatermarkKind.text && _textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('워터마크 텍스트를 입력하세요.')));
      return;
    }
    if (_kind == _WatermarkKind.image && _imageBytes == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('워터마크 이미지를 선택하세요.')));
      return;
    }

    setState(() => _busy = true);
    try {
      final output = await PdfService.addWatermark(
        file: widget.file,
        sourceName: widget.fileName,
        text: _kind == _WatermarkKind.text ? _textController.text.trim() : null,
        imageBytes: _kind == _WatermarkKind.image ? _imageBytes : null,
        opacity: _opacity,
        rotationDegrees: _rotation,
        tile: _tile,
      );
      final saved = await AndroidFileService.savePdf(
        sourcePath: output.path,
        fileName:
            '${widget.fileName.replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '')}_watermarked.pdf',
      );
      if (saved && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('워터마크를 적용해 저장했습니다.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('워터마크 적용 실패: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('워터마크')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              RadioGroup<_WatermarkKind>(
                groupValue: _kind,
                onChanged: (value) {
                  if (value != null) setState(() => _kind = value);
                },
                child: Row(
                  children: [
                    Expanded(
                      child: RadioListTile<_WatermarkKind>(
                        value: _WatermarkKind.text,
                        title: const Text('텍스트'),
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<_WatermarkKind>(
                        value: _WatermarkKind.image,
                        title: const Text('이미지'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (_kind == _WatermarkKind.text)
                TextField(
                  controller: _textController,
                  decoration: const InputDecoration(
                    labelText: '워터마크 텍스트',
                    border: OutlineInputBorder(),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickImage,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('이미지 선택'),
                    ),
                    if (_imageBytes != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Image.memory(
                          _imageBytes!,
                          height: 100,
                          fit: BoxFit.contain,
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 24),
              Text('투명도: ${(_opacity * 100).round()}%'),
              Slider(
                value: _opacity,
                min: 0.05,
                max: 0.9,
                onChanged: (value) => setState(() => _opacity = value),
              ),
              Text('회전 각도: ${_rotation.round()}°'),
              Slider(
                value: _rotation,
                min: -90,
                max: 90,
                onChanged: (value) => setState(() => _rotation = value),
              ),
              SwitchListTile(
                value: _tile,
                onChanged: (value) => setState(() => _tile = value),
                title: const Text('페이지 전체에 반복'),
                subtitle: const Text('끄면 페이지 가운데에 한 번만 표시'),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _apply,
                icon: const Icon(Icons.water_drop_outlined),
                label: const Text('워터마크 적용 후 저장'),
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
