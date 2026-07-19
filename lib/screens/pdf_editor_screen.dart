import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:signature/signature.dart';
import 'package:uuid/uuid.dart';

import '../models/editor_item.dart';
import '../services/drive_service.dart';
import '../services/pdf_service.dart';

class PdfEditorScreen extends StatefulWidget {
  const PdfEditorScreen({
    super.key,
    required this.pdfFile,
    required this.fileName,
  });

  final File pdfFile;
  final String fileName;

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  final _uuid = const Uuid();
  final _pageController = PageController();
  final _picker = ImagePicker();
  final _drive = DriveService();
  final List<EditorItem> _items = [];
  final List<List<EditorItem>> _undo = [];
  final List<List<EditorItem>> _redo = [];

  List<RenderedPdfPage> _pages = [];
  int _pageIndex = 0;
  String? _selectedId;
  bool _loading = true;
  bool _exporting = false;
  bool _drawingMode = false;
  List<DrawingPoint> _activeStroke = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final pages = await PdfService.renderAllPages(widget.pdfFile);
      if (mounted) {
        setState(() => _pages = pages);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 로딩 실패: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<EditorItem> _snapshot() => _items.map((item) => item.copy()).toList();

  void _commit() {
    _undo.add(_snapshot());
    _redo.clear();
  }

  void _undoAction() {
    if (_undo.isEmpty) return;
    _redo.add(_snapshot());
    setState(() {
      _items
        ..clear()
        ..addAll(_undo.removeLast().map((item) => item.copy()));
      _selectedId = null;
    });
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    _undo.add(_snapshot());
    setState(() {
      _items
        ..clear()
        ..addAll(_redo.removeLast().map((item) => item.copy()));
      _selectedId = null;
    });
  }

  Future<void> _addText() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('텍스트 추가'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('추가'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (text == null || text.isEmpty) return;
    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.text,
        pageIndex: _pageIndex,
        x: 0.1,
        y: 0.12,
        width: 0.5,
        height: 0.1,
        text: text,
      );
      _items.add(item);
      _selectedId = item.id;
    });
  }

  void _addCheck() {
    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.check,
        pageIndex: _pageIndex,
        x: 0.12,
        y: 0.18,
        width: 0.1,
        height: 0.08,
      );
      _items.add(item);
      _selectedId = item.id;
    });
  }

  Future<void> _addSignature() async {
    final controller = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.transparent,
    );
    final bytes = await showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '서명',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 220,
                child: Signature(
                  controller: controller,
                  backgroundColor: Colors.white,
                ),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: controller.clear,
                    child: const Text('지우기'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
                      final imageBytes = await controller.toPngBytes();
                      if (sheetContext.mounted && imageBytes != null) {
                        Navigator.pop(sheetContext, imageBytes);
                      }
                    },
                    child: const Text('추가'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    controller.dispose();

    if (bytes == null) return;
    _addImageBytes(bytes, EditorItemType.signature);
  }

  Future<void> _pickImage(EditorItemType type) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('사진 앨범'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('카메라'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final file = await _picker.pickImage(source: source, imageQuality: 92);
    if (file == null) return;
    _addImageBytes(await file.readAsBytes(), type);
  }

  void _addImageBytes(Uint8List bytes, EditorItemType type) {
    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: type,
        pageIndex: _pageIndex,
        x: 0.15,
        y: 0.2,
        width: 0.35,
        height: 0.18,
        bytes: bytes,
      );
      _items.add(item);
      _selectedId = item.id;
    });
  }

  void _deleteSelected() {
    if (_selectedId == null) return;
    _commit();
    setState(() {
      _items.removeWhere((item) => item.id == _selectedId);
      _selectedId = null;
    });
  }

  void _startStroke(DragStartDetails details, Size size) {
    if (!_drawingMode) return;
    _activeStroke = [
      DrawingPoint(
        details.localPosition.dx / size.width,
        details.localPosition.dy / size.height,
      ),
    ];
  }

  void _updateStroke(DragUpdateDetails details, Size size) {
    if (!_drawingMode) return;
    final dx = (details.localPosition.dx / size.width).clamp(0.0, 1.0).toDouble();
    final dy = (details.localPosition.dy / size.height).clamp(0.0, 1.0).toDouble();
    setState(() => _activeStroke.add(DrawingPoint(dx, dy)));
  }

  void _endStroke(DragEndDetails details) {
    if (!_drawingMode || _activeStroke.length < 2) return;
    _commit();
    setState(() {
      _items.add(
        EditorItem(
          id: _uuid.v4(),
          type: EditorItemType.drawing,
          pageIndex: _pageIndex,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          points: List.of(_activeStroke),
          strokeWidth: 3,
        ),
      );
      _activeStroke = [];
    });
  }

  Future<File?> _exportFile() async {
    if (_pages.isEmpty) return null;
    setState(() => _exporting = true);
    try {
      return await PdfService.exportMultiPagePdf(
        pages: _pages,
        items: _items,
        sourceName: widget.fileName,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share() async {
    final file = await _exportFile();
    if (file == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: file.uri.pathSegments.last,
      ),
    );
  }

  Future<void> _saveDrive() async {
    try {
      final file = await _exportFile();
      if (file == null) return;
      await _drive.upload(file);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Google Drive에 저장했습니다.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Drive 저장 실패: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.fileName}  ${_pages.isEmpty ? '' : '${_pageIndex + 1}/${_pages.length}'}',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: _undo.isEmpty ? null : _undoAction,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            onPressed: _redo.isEmpty ? null : _redoAction,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            onPressed: _selectedId == null ? null : _deleteSelected,
            icon: const Icon(Icons.delete_outline),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'share') _share();
              if (value == 'drive') _saveDrive();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'share',
                child: ListTile(
                  leading: Icon(Icons.share),
                  title: Text('저장 및 공유'),
                ),
              ),
              PopupMenuItem(
                value: 'drive',
                child: ListTile(
                  leading: Icon(Icons.cloud_upload),
                  title: Text('Google Drive 저장'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _pages.isEmpty
              ? const Center(child: Text('표시할 페이지가 없습니다.'))
              : PageView.builder(
                  controller: _pageController,
                  itemCount: _pages.length,
                  onPageChanged: (index) => setState(() {
                    _pageIndex = index;
                    _selectedId = null;
                    _activeStroke = [];
                  }),
                  itemBuilder: (_, index) => _buildPage(index),
                ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _drawingMode ? 2 : 0,
        onDestinationSelected: (index) {
          if (index == 0) _addText();
          if (index == 1) _addCheck();
          if (index == 2) setState(() => _drawingMode = !_drawingMode);
          if (index == 3) _addSignature();
          if (index == 4) _showMore();
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.text_fields),
            label: '텍스트',
          ),
          const NavigationDestination(
            icon: Icon(Icons.check_box_outlined),
            label: '체크',
          ),
          NavigationDestination(
            icon: Icon(_drawingMode ? Icons.edit_off : Icons.draw),
            label: _drawingMode ? '필기 종료' : '자유 필기',
          ),
          const NavigationDestination(
            icon: Icon(Icons.gesture),
            label: '서명',
          ),
          const NavigationDestination(
            icon: Icon(Icons.add_circle_outline),
            label: '더보기',
          ),
        ],
      ),
    );
  }

  void _showMore() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('사진 추가'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(EditorItemType.image);
              },
            ),
            ListTile(
              leading: const Icon(Icons.approval),
              title: const Text('도장 이미지 추가'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(EditorItemType.stamp);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(int index) {
    final page = _pages[index];
    return Center(
      child: AspectRatio(
        aspectRatio: page.aspectRatio,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final pageItems = _items.where((item) => item.pageIndex == index).toList();
            return GestureDetector(
              onTap: () => setState(() => _selectedId = null),
              onPanStart: (details) => _startStroke(details, size),
              onPanUpdate: (details) => _updateStroke(details, size),
              onPanEnd: _endStroke,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Image.memory(page.bytes, fit: BoxFit.fill),
                  ),
                  ...pageItems.map((item) => _itemWidget(item, size)),
                  if (_activeStroke.isNotEmpty)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _StrokePainter(_activeStroke, Colors.black, 3),
                      ),
                    ),
                  if (_drawingMode)
                    const Positioned(
                      top: 8,
                      left: 8,
                      child: Chip(label: Text('필기 모드')),
                    ),
                  if (_exporting)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0x33000000),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _itemWidget(EditorItem item, Size size) {
    if (item.type == EditorItemType.drawing) {
      return Positioned.fill(
        child: CustomPaint(
          painter: _StrokePainter(
            item.points,
            Color(item.colorValue),
            item.strokeWidth,
          ),
        ),
      );
    }

    final selected = _selectedId == item.id;
    final Widget child;
    if (item.type == EditorItemType.text) {
      child = Text(
        item.text ?? '',
        style: TextStyle(
          fontSize: item.fontSize,
          color: Color(item.colorValue),
        ),
      );
    } else if (item.type == EditorItemType.check) {
      child = const FittedBox(child: Text('✓'));
    } else {
      child = item.bytes == null
          ? const SizedBox()
          : Image.memory(item.bytes!, fit: BoxFit.contain);
    }

    return Positioned(
      left: item.x * size.width,
      top: item.y * size.height,
      width: item.width * size.width,
      height: item.height * size.height,
      child: GestureDetector(
        onTap: () {
          if (!_drawingMode) setState(() => _selectedId = item.id);
        },
        onPanStart: (_) {
          if (!_drawingMode) _commit();
        },
        onPanUpdate: (details) {
          if (_drawingMode) return;
          setState(() {
            item.x = (item.x + details.delta.dx / size.width)
                .clamp(0.0, 1.0 - item.width)
                .toDouble();
            item.y = (item.y + details.delta.dy / size.height)
                .clamp(0.0, 1.0 - item.height)
                .toDouble();
          });
        },
        child: Container(
          decoration: BoxDecoration(
            border: selected
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.points, this.color, this.width);

  final List<DrawingPoint> points;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final first = points.first.toOffset(size);
    path.moveTo(first.dx, first.dy);
    for (final point in points.skip(1)) {
      final offset = point.toOffset(size);
      path.lineTo(offset.dx, offset.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}
