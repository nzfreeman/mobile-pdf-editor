import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:signature/signature.dart';
import 'package:uuid/uuid.dart';

import '../models/editor_item.dart';
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
  static const _palette = <Color>[
    Colors.black,
    Color(0xFFEF4444),
    Color(0xFFF59E0B),
    Color(0xFF22C55E),
    Color(0xFF06B6D4),
    Color(0xFF3B82F6),
    Color(0xFF8B5CF6),
  ];

  final _uuid = const Uuid();
  final _pageController = PageController();
  final _transformController = TransformationController();
  final _objectToolbarController = ScrollController();
  final _picker = ImagePicker();
  final List<EditorItem> _items = [];
  final List<List<EditorItem>> _undo = [];
  final List<List<EditorItem>> _redo = [];

  List<RenderedPdfPage> _pages = [];
  EditorItem? _clipboard;
  int _pageIndex = 0;
  String? _selectedId;
  bool _loading = true;
  bool _exporting = false;
  bool _drawingMode = false;
  bool _showMoreToolsIndicator = true;
  bool _resizingItem = false;
  bool _rotatingItem = false;
  double _zoomScale = 1;
  List<DrawingPoint> _activeStroke = [];

  EditorItem? get _selectedItem {
    final id = _selectedId;
    if (id == null) return null;
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _objectToolbarController.addListener(_updateToolbarIndicator);
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _transformController.dispose();
    _objectToolbarController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final pages = await PdfService.renderAllPages(widget.pdfFile);
      if (mounted) setState(() => _pages = pages);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 로딩 실패: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<EditorItem> _snapshot() => _items.map((item) => item.copy()).toList();

  void _commit() {
    _undo.add(_snapshot());
    if (_undo.length > 100) _undo.removeAt(0);
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

  Future<String?> _textDialog({
    String initialText = '',
    required String title,
    int maxLines = 8,
  }) async {
    final controller = TextEditingController(text: initialText);
    controller.selection = TextSelection.fromPosition(
      TextPosition(offset: controller.text.length),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: maxLines == 1 ? 1 : 3,
          maxLines: maxLines,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              controller.text.trim(),
            ),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  void _addTextItem({
    required String text,
    double width = 0.46,
    double height = 0.1,
    double fontSize = 18,
  }) {
    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.text,
        pageIndex: _pageIndex,
        x: 0.12,
        y: 0.15,
        width: width,
        height: height,
        text: text,
        fontSize: fontSize,
      );
      _items.add(item);
      _selectedId = item.id;
      _drawingMode = false;
    });
  }

  Future<void> _addText() async {
    final text = await _textDialog(title: '텍스트 추가');
    if (text == null || text.isEmpty) return;
    _addTextItem(text: text);
  }

  Future<void> _addInitials() async {
    final initials = await _textDialog(title: '이니셜 입력', maxLines: 1);
    if (initials == null || initials.isEmpty) return;
    _addTextItem(
      text: initials.toUpperCase(),
      width: 0.18,
      height: 0.08,
      fontSize: 22,
    );
  }

  void _addDate() {
    final now = DateTime.now();
    final date =
        '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/${now.year}';
    _addTextItem(text: date, width: 0.3, height: 0.07, fontSize: 16);
  }

  Future<void> _editText(EditorItem item) async {
    if (item.type != EditorItemType.text) return;
    final text = await _textDialog(
      initialText: item.text ?? '',
      title: '텍스트 수정',
    );
    if (text == null || text == item.text) return;
    _commit();
    setState(() => item.text = text);
  }

  void _addCheck() {
    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.check,
        pageIndex: _pageIndex,
        x: 0.15,
        y: 0.2,
        width: 0.09,
        height: 0.07,
      );
      _items.add(item);
      _selectedId = item.id;
      _drawingMode = false;
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
    if (bytes != null) _addImageBytes(bytes, EditorItemType.signature);
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
    if (file != null) _addImageBytes(await file.readAsBytes(), type);
  }

  void _addImageBytes(Uint8List bytes, EditorItemType type) {
    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: type,
        pageIndex: _pageIndex,
        x: 0.16,
        y: 0.22,
        width: 0.34,
        height: 0.18,
        bytes: bytes,
      );
      _items.add(item);
      _selectedId = item.id;
      _drawingMode = false;
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

  void _copySelected() {
    final item = _selectedItem;
    if (item == null) return;
    setState(() => _clipboard = item.copy());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('개체를 복사했습니다.')),
    );
  }

  void _duplicateSelected() {
    final source = _selectedItem;
    if (source == null) return;
    _commit();
    final item = source.copyWith(
      id: _uuid.v4(),
      x: (source.x + 0.035).clamp(0.0, 1.0 - source.width).toDouble(),
      y: (source.y + 0.035).clamp(0.0, 1.0 - source.height).toDouble(),
    );
    setState(() {
      _items.add(item);
      _selectedId = item.id;
    });
  }

  void _pasteClipboard() {
    final source = _clipboard;
    if (source == null) return;
    _commit();
    final item = source.copyWith(
      id: _uuid.v4(),
      pageIndex: _pageIndex,
      x: (source.x + 0.035).clamp(0.0, 1.0 - source.width).toDouble(),
      y: (source.y + 0.035).clamp(0.0, 1.0 - source.height).toDouble(),
    );
    setState(() {
      _items.add(item);
      _selectedId = item.id;
      _drawingMode = false;
    });
  }

  void _setSelectedColor(Color color) {
    final item = _selectedItem;
    if (item == null) return;
    _commit();
    setState(() => item.colorValue = color.toARGB32());
  }

  void _changeSelectedSize(double factor) {
    final item = _selectedItem;
    if (item == null) return;
    _commit();
    setState(() {
      if (item.type == EditorItemType.text) {
        item.fontSize = (item.fontSize * factor).clamp(8.0, 96.0).toDouble();
      } else if (item.type == EditorItemType.drawing) {
        item.strokeWidth =
            (item.strokeWidth * factor).clamp(1.0, 16.0).toDouble();
      } else {
        item.width =
            (item.width * factor).clamp(0.045, 1.0 - item.x).toDouble();
        item.height =
            (item.height * factor).clamp(0.035, 1.0 - item.y).toDouble();
      }
    });
  }

  void _rotateSelected(double amount) {
    final item = _selectedItem;
    if (item == null) return;
    _commit();
    setState(() => item.rotation += amount);
  }

  void _startStroke(DragStartDetails details, Size size) {
    if (!_drawingMode) return;
    _activeStroke = [
      DrawingPoint(
        (details.localPosition.dx / size.width).clamp(0.0, 1.0).toDouble(),
        (details.localPosition.dy / size.height).clamp(0.0, 1.0).toDouble(),
      ),
    ];
  }

  void _updateStroke(DragUpdateDetails details, Size size) {
    if (!_drawingMode) return;
    final dx =
        (details.localPosition.dx / size.width).clamp(0.0, 1.0).toDouble();
    final dy =
        (details.localPosition.dy / size.height).clamp(0.0, 1.0).toDouble();
    setState(() => _activeStroke.add(DrawingPoint(dx, dy)));
  }

  void _endStroke(DragEndDetails details) {
    if (!_drawingMode || _activeStroke.length < 2) return;
    var minX = 1.0;
    var minY = 1.0;
    var maxX = 0.0;
    var maxY = 0.0;
    for (final point in _activeStroke) {
      minX = math.min(minX, point.dx);
      minY = math.min(minY, point.dy);
      maxX = math.max(maxX, point.dx);
      maxY = math.max(maxY, point.dy);
    }
    const padding = 0.012;
    minX = (minX - padding).clamp(0.0, 1.0);
    minY = (minY - padding).clamp(0.0, 1.0);
    maxX = (maxX + padding).clamp(0.0, 1.0);
    maxY = (maxY + padding).clamp(0.0, 1.0);
    final width = math.max(0.035, maxX - minX);
    final height = math.max(0.035, maxY - minY);
    final localPoints = _activeStroke
        .map(
          (point) => DrawingPoint(
            ((point.dx - minX) / width).clamp(0.0, 1.0).toDouble(),
            ((point.dy - minY) / height).clamp(0.0, 1.0).toDouble(),
          ),
        )
        .toList();

    _commit();
    final item = EditorItem(
      id: _uuid.v4(),
      type: EditorItemType.drawing,
      pageIndex: _pageIndex,
      x: minX,
      y: minY,
      width: width,
      height: height,
      points: localPoints,
      strokeWidth: 3,
    );
    setState(() {
      _items.add(item);
      _selectedId = item.id;
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

  Future<void> _savePdf() async {
    // File picker functionality removed (file_picker dependency removed)
    // TODO: Implement alternative file selection mechanism
    return;
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

  void _resetView() {
    _transformController.value = Matrix4.identity();
    if (_zoomScale != 1) setState(() => _zoomScale = 1);
  }

  void _toggleZoom() {
    if (_zoomScale > 1.05) {
      _resetView();
      return;
    }
    _transformController.value = Matrix4.diagonal3Values(2.0, 2.0, 1.0);
    setState(() => _zoomScale = 2.0);
  }

  void _updateToolbarIndicator() {
    if (!_objectToolbarController.hasClients) return;
    final position = _objectToolbarController.position;
    final show = position.maxScrollExtent > 8 &&
        position.pixels < position.maxScrollExtent - 8;
    if (show != _showMoreToolsIndicator && mounted) {
      setState(() => _showMoreToolsIndicator = show);
    }
  }

  void _scrollObjectToolbarForward() {
    if (!_objectToolbarController.hasClients) return;
    final position = _objectToolbarController.position;
    _objectToolbarController.animateTo(
      math.min(position.pixels + 230, position.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _goToPage(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
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
            tooltip: '화면 맞춤',
            onPressed: _resetView,
            icon: const Icon(Icons.fit_screen),
          ),
          IconButton(
            tooltip: '실행 취소',
            onPressed: _undo.isEmpty ? null : _undoAction,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: '다시 실행',
            onPressed: _redo.isEmpty ? null : _redoAction,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: 'PDF 저장',
            onPressed: _exporting ? null : _savePdf,
            icon: const Icon(Icons.save_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'copy') _copySelected();
              if (value == 'paste') _pasteClipboard();
              if (value == 'share') _share();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'copy',
                enabled: _selectedItem != null,
                child: const ListTile(
                  leading: Icon(Icons.copy),
                  title: Text('복사'),
                ),
              ),
              PopupMenuItem(
                value: 'paste',
                enabled: _clipboard != null,
                child: const ListTile(
                  leading: Icon(Icons.paste),
                  title: Text('붙여넣기'),
                ),
              ),
              const PopupMenuItem(
                value: 'share',
                child: ListTile(
                  leading: Icon(Icons.share),
                  title: Text('저장 및 공유'),
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
              : Column(
                  children: [
                    _buildInsertToolbar(),
                    Expanded(
                      child: PageView.builder(
                        controller: _pageController,
                        physics: _drawingMode ||
                                _selectedId != null ||
                                _zoomScale > 1.01
                            ? const NeverScrollableScrollPhysics()
                            : const PageScrollPhysics(),
                        itemCount: _pages.length,
                        onPageChanged: (index) {
                          setState(() {
                            _pageIndex = index;
                            _selectedId = null;
                            _activeStroke = [];
                          });
                          _resetView();
                        },
                        itemBuilder: (_, index) => _buildPage(index),
                      ),
                    ),
                  ],
                ),
      bottomNavigationBar: _pages.isEmpty
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_selectedItem != null || _drawingMode)
                  _buildObjectToolbar(),
                _buildThumbnails(),
              ],
            ),
    );
  }

  Widget _buildInsertToolbar() {
    return Material(
      elevation: 2,
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 78,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          scrollDirection: Axis.horizontal,
          children: [
            _insertTool(Icons.title, '텍스트', _addText),
            _insertTool(Icons.check_box_outlined, '체크', _addCheck),
            _insertTool(
              Icons.image_outlined,
              '이미지',
              () => _pickImage(EditorItemType.image),
            ),
            _insertTool(Icons.badge_outlined, '이니셜', _addInitials),
            _insertTool(Icons.gesture, '서명', _addSignature),
            _insertTool(Icons.calendar_today_outlined, '날짜', _addDate),
            _insertTool(
              _drawingMode ? Icons.edit_off : Icons.draw,
              _drawingMode ? '필기 종료' : '자유 필기',
              () {
                setState(() {
                  _drawingMode = !_drawingMode;
                  _selectedId = null;
                  _activeStroke = [];
                });
                _resetView();
              },
              selected: _drawingMode,
            ),
            _insertTool(Icons.more_horiz, '더보기', _showMore),
          ],
        ),
      ),
    );
  }

  Widget _insertTool(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool selected = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 68,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildObjectToolbar() {
    final selected = _selectedItem;
    final supportsColor = selected == null ||
        selected.type == EditorItemType.text ||
        selected.type == EditorItemType.check ||
        selected.type == EditorItemType.drawing;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateToolbarIndicator();
    });

    return Material(
      elevation: 6,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: 72,
          child: Stack(
            children: [
              ListView(
                controller: _objectToolbarController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(10, 8, 72, 8),
                children: [
                  if (supportsColor)
                    ..._palette.map(
                      (color) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: selected == null
                              ? null
                              : () => _setSelectedColor(color),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected?.colorValue == color.toARGB32()
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.white,
                                width: 3,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (selected != null) ...[
                    const VerticalDivider(),
                    _toolbarAction(
                      icon: Icons.remove,
                      label: '작게',
                      onTap: () => _changeSelectedSize(0.9),
                    ),
                    _toolbarAction(
                      icon: Icons.add,
                      label: '크게',
                      onTap: () => _changeSelectedSize(1.1),
                    ),
                    _toolbarAction(
                      icon: Icons.rotate_left,
                      label: '왼쪽',
                      onTap: () => _rotateSelected(-math.pi / 12),
                    ),
                    _toolbarAction(
                      icon: Icons.rotate_right,
                      label: '오른쪽',
                      onTap: () => _rotateSelected(math.pi / 12),
                    ),
                    _toolbarAction(
                      icon: Icons.control_point_duplicate,
                      label: '복제',
                      onTap: _duplicateSelected,
                    ),
                    if (selected.type == EditorItemType.text)
                      _toolbarAction(
                        icon: Icons.edit,
                        label: '수정',
                        onTap: () => _editText(selected),
                      ),
                    _toolbarAction(
                      icon: Icons.delete_outline,
                      label: '삭제',
                      onTap: _deleteSelected,
                      danger: true,
                    ),
                  ],
                ],
              ),
              if (_showMoreToolsIndicator)
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 70,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0),
                          Theme.of(context).colorScheme.surface,
                          Theme.of(context).colorScheme.surface,
                        ],
                      ),
                    ),
                    child: InkWell(
                      onTap: _scrollObjectToolbarForward,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chevron_right,
                            color: Theme.of(context).colorScheme.primary,
                            size: 28,
                          ),
                          Text(
                            '더보기',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbarAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnails() {
    return Material(
      elevation: 2,
      child: SizedBox(
        height: 92,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          scrollDirection: Axis.horizontal,
          itemCount: _pages.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, index) {
            final selected = index == _pageIndex;
            return InkWell(
              onTap: () => _goToPage(index),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 58,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.black26,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(3),
                      child: Image.memory(
                        _pages[index].bytes,
                        fit: BoxFit.contain,
                      ),
                    ),
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
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
              leading: const Icon(Icons.approval),
              title: const Text('도장 이미지 추가'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(EditorItemType.stamp);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('선택 개체 복사'),
              enabled: _selectedItem != null,
              onTap: _selectedItem == null
                  ? null
                  : () {
                      Navigator.pop(sheetContext);
                      _copySelected();
                    },
            ),
            ListTile(
              leading: const Icon(Icons.paste),
              title: const Text('붙여넣기'),
              enabled: _clipboard != null,
              onTap: _clipboard == null
                  ? null
                  : () {
                      Navigator.pop(sheetContext);
                      _pasteClipboard();
                    },
            ),
            ListTile(
              leading: const Icon(Icons.save_outlined),
              title: const Text('PDF 저장'),
              onTap: () {
                Navigator.pop(sheetContext);
                _savePdf();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(int index) {
    final page = _pages[index];
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = math.max(1.0, constraints.maxWidth);
        final availableHeight = math.max(1.0, constraints.maxHeight);
        var pageWidth = availableWidth;
        var pageHeight = pageWidth / page.aspectRatio;
        if (pageHeight > availableHeight) {
          pageHeight = availableHeight;
          pageWidth = pageHeight * page.aspectRatio;
        }
        final pageSize = Size(pageWidth, pageHeight);
        final pageItems =
            _items.where((item) => item.pageIndex == index).toList();

        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _transformController,
                constrained: false,
                alignment: Alignment.center,
                clipBehavior: Clip.hardEdge,
                boundaryMargin: const EdgeInsets.all(100),
                minScale: 0.5,
                maxScale: 8,
                panEnabled: true,
                scaleEnabled: true,
                onInteractionUpdate: (_) {
                  final scale = _transformController.value.getMaxScaleOnAxis();
                  if ((scale - _zoomScale).abs() > 0.02) {
                    setState(() => _zoomScale = scale);
                  }
                },
                onInteractionEnd: (_) {
                  final scale = _transformController.value.getMaxScaleOnAxis();
                  if ((scale - _zoomScale).abs() > 0.005) {
                    setState(() => _zoomScale = scale);
                  }
                },
                child: Center(
                  child: SizedBox(
                    width: pageWidth,
                    height: pageHeight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (!_drawingMode) setState(() => _selectedId = null);
                      },
                      onDoubleTap: _drawingMode ? null : _toggleZoom,
                      onPanStart: _drawingMode
                          ? (details) => _startStroke(details, pageSize)
                          : null,
                      onPanUpdate: _drawingMode
                          ? (details) => _updateStroke(details, pageSize)
                          : null,
                      onPanEnd: _drawingMode ? _endStroke : null,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                    blurRadius: 8,
                                    color: Color(0x33000000),
                                  ),
                                ],
                              ),
                              child: Image.memory(page.bytes, fit: BoxFit.fill),
                            ),
                          ),
                          ...pageItems.map(
                            (item) => _itemWidget(item, pageSize),
                          ),
                          if (_activeStroke.isNotEmpty)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _StrokePainter(
                                    _activeStroke,
                                    Colors.black,
                                    3,
                                  ),
                                ),
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
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 10,
              child: Material(
                color: Theme.of(context)
                    .colorScheme
                    .inverseSurface
                    .withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  onTap: _resetView,
                  borderRadius: BorderRadius.circular(18),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Text(
                      '${(_zoomScale * 100).round()}%',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onInverseSurface,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _itemWidget(EditorItem item, Size pageSize) {
    final selected = _selectedId == item.id;
    final itemWidth = item.width * pageSize.width;
    final itemHeight = item.height * pageSize.height;

    final Widget content;
    if (item.type == EditorItemType.text) {
      content = Align(
        alignment: Alignment.topLeft,
        child: Text(
          item.text ?? '',
          style: TextStyle(
            fontSize: item.fontSize,
            color: Color(item.colorValue),
          ),
        ),
      );
    } else if (item.type == EditorItemType.check) {
      content = FittedBox(
        child: Text('✓', style: TextStyle(color: Color(item.colorValue))),
      );
    } else if (item.type == EditorItemType.drawing) {
      content = CustomPaint(
        painter: _StrokePainter(
          item.points,
          Color(item.colorValue),
          item.strokeWidth,
        ),
      );
    } else {
      content = item.bytes == null
          ? const SizedBox()
          : Image.memory(item.bytes!, fit: BoxFit.contain);
    }

    return Positioned(
      left: item.x * pageSize.width,
      top: item.y * pageSize.height,
      width: itemWidth,
      height: itemHeight,
      child: Transform.rotate(
        angle: item.rotation,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!_drawingMode) {
                    setState(() {
                      _selectedId = item.id;
                      _showMoreToolsIndicator = true;
                    });
                    if (_objectToolbarController.hasClients) {
                      _objectToolbarController.jumpTo(0);
                    }
                  }
                },
                onDoubleTap: item.type == EditorItemType.text
                    ? () => _editText(item)
                    : null,
                onPanStart: (_) {
                  if (_drawingMode) return;
                  _commit();
                  setState(() => _selectedId = item.id);
                },
                onPanUpdate: (details) {
                  if (_drawingMode) return;
                  setState(() {
                    item.x = (item.x + details.delta.dx / pageSize.width)
                        .clamp(0.0, 1.0 - item.width)
                        .toDouble();
                    item.y = (item.y + details.delta.dy / pageSize.height)
                        .clamp(0.0, 1.0 - item.height)
                        .toDouble();
                  });
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: selected
                        ? Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2.5,
                          )
                        : null,
                  ),
                  child: Padding(
                    padding: selected
                        ? const EdgeInsets.all(2)
                        : EdgeInsets.zero,
                    child: content,
                  ),
                ),
              ),
            ),
            if (selected) ...[
              Positioned(
                top: -58,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) {
                      _commit();
                      setState(() => _rotatingItem = true);
                    },
                    onPanUpdate: (details) {
                      setState(() => item.rotation += details.delta.dx * 0.018);
                    },
                    onPanEnd: (_) => setState(() => _rotatingItem = false),
                    onPanCancel: () => setState(() => _rotatingItem = false),
                    child: _handle(
                      icon: Icons.rotate_right,
                      tooltip: '좌우로 드래그하여 회전',
                      active: _rotatingItem,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -25,
                bottom: -25,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) {
                    _commit();
                    setState(() => _resizingItem = true);
                  },
                  onPanUpdate: (details) {
                    setState(() {
                      final oldWidth = item.width;
                      final nextWidth =
                          (item.width + details.delta.dx / pageSize.width)
                              .clamp(0.045, 1.0 - item.x)
                              .toDouble();
                      final nextHeight =
                          (item.height + details.delta.dy / pageSize.height)
                              .clamp(0.035, 1.0 - item.y)
                              .toDouble();
                      item.width = nextWidth;
                      item.height = nextHeight;
                      if (item.type == EditorItemType.text && oldWidth > 0) {
                        item.fontSize = (item.fontSize * nextWidth / oldWidth)
                            .clamp(8.0, 96.0)
                            .toDouble();
                      }
                    });
                  },
                  onPanEnd: (_) => setState(() => _resizingItem = false),
                  onPanCancel: () => setState(() => _resizingItem = false),
                  child: _handle(
                    icon: Icons.open_in_full,
                    tooltip: '드래그하여 크기 조절',
                    active: _resizingItem,
                  ),
                ),
              ),
              Positioned(
                left: -25,
                top: -25,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _deleteSelected,
                  child: _handle(
                    icon: Icons.close,
                    tooltip: '삭제',
                    danger: true,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _handle({
    required IconData icon,
    required String tooltip,
    bool danger = false,
    bool active = false,
  }) {
    final baseColor = danger
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 52,
        height: 52,
        alignment: Alignment.center,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: active ? 46 : 42,
          height: active ? 46 : 42,
          decoration: BoxDecoration(
            color: active ? baseColor.withValues(alpha: 0.82) : baseColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: active ? 3 : 2),
            boxShadow: [
              BoxShadow(
                blurRadius: active ? 8 : 4,
                spreadRadius: active ? 2 : 0,
                color: const Color(0x66000000),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: active ? 25 : 22),
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
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
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
