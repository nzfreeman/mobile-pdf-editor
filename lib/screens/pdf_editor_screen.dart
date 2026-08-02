import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:signature/signature.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/editor_item.dart';
import '../services/android_file_service.dart';
import '../services/ocr_service.dart';
import '../services/pdf_native/pdf_content_stream.dart';
import '../services/pdf_native/pdf_document.dart';
import '../services/pdf_native/pdf_link_annotations.dart';
import '../services/pdf_native/pdf_native_edit_builder.dart';
import '../services/pdf_native/pdf_native_text_service.dart';
import '../services/pdf_service.dart';
import '../widgets/experimental_pdf_notice.dart';

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
  Color _drawColor = Colors.black;
  double _drawStrokeWidth = 3;
  bool _showMoreToolsIndicator = true;

  /// Tap-to-toggle mode for the selected item's rotate/resize handles:
  /// null (neither active), 'rotate', or 'resize'. While set, dragging
  /// anywhere on the item rotates/resizes it instead of moving it — the
  /// handle icon itself is now a mode toggle, not something you drag
  /// directly (small drag targets on a floating circle were fiddly;
  /// this also matches how most mobile editors handle this).
  String? _activeGizmoMode;

  /// Whether tapping on the page should hit-test the PDF's own text runs
  /// for direct in-place editing, instead of the toolbar action opening a
  /// flat list of every text run on the page up front.
  bool _textEditTapMode = false;
  List<PdfTextRun> _textEditRunsOnPage = [];
  List<PdfLinkAnnotation> _links = [];
  bool _recognizing = false;
  late File _currentFile = widget.pdfFile;
  bool _hasNativeTextEdits = false;
  bool _shownNativeEditNotice = false;
  final Map<String, GlobalKey> _itemContentKeys = {};
  double? _rotateStartAngle;
  double _rotateStartRotation = 0;
  double _zoomScale = 1;
  List<DrawingPoint> _activeStroke = [];

  /// The selection handles (rotate/resize/delete) live inside the same
  /// InteractiveViewer-transformed subtree as the page content, so
  /// without this they'd visually grow with the zoom level along with
  /// everything else — at high zoom they end up covering most of the
  /// screen. Scaling them by the inverse of the current zoom keeps their
  /// on-screen size constant regardless of how far the user has zoomed
  /// in. Clamped so they never shrink to the point of being untappable.
  double get _inverseZoom => (1 / _zoomScale).clamp(0.25, 1.0);

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
      final pages = await PdfService.renderAllPages(_currentFile);
      if (mounted) setState(() => _pages = pages);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF 로딩 실패: $error')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    await _loadLinks();
  }

  /// Best-effort: link annotations are a nice-to-have overlay on top of
  /// the rendered page image, not a core editing feature, so any parse
  /// failure (encrypted PDF, unsupported filter, etc.) just means no
  /// clickable links rather than blocking the page from loading at all.
  Future<void> _loadLinks() async {
    List<PdfLinkAnnotation> links = [];
    try {
      final bytes = await _currentFile.readAsBytes();
      final doc = PdfDocument.parse(bytes);
      links = extractLinkAnnotations(doc);
    } catch (_) {
      links = [];
    }
    if (mounted) setState(() => _links = links);
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
      _activeGizmoMode = null;
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
      _activeGizmoMode = null;
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
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
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
    if (item.type != EditorItemType.text && item.type != EditorItemType.memo) {
      return;
    }
    final text = await _textDialog(
      initialText: item.text ?? '',
      title: item.type == EditorItemType.memo ? '메모 수정' : '텍스트 수정',
    );
    if (text == null || text == item.text) return;
    _commit();
    setState(() => item.text = text);
  }

  /// null = cancelled, true = internal page-jump link, false = external URL.
  Future<bool?> _askLinkType() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('링크 종류 선택'),
        content: const Text('외부 웹사이트로 연결할지, 이 문서의 다른 페이지로 이동할지 선택하세요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, null),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('문서 내 페이지'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('외부 URL'),
          ),
        ],
      ),
    );
  }

  Future<int?> _askPageNumber({int? initial}) async {
    final input = await _textDialog(
      initialText: initial == null ? '' : '${initial + 1}',
      title: '이동할 페이지 번호 (1~${_pages.length})',
      maxLines: 1,
    );
    if (input == null) return null;
    final page = int.tryParse(input.trim());
    if (page == null || page < 1 || page > _pages.length) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('1~${_pages.length} 사이의 페이지 번호를 입력하세요.')),
        );
      }
      return null;
    }
    return page - 1;
  }

  Future<void> _editLink(EditorItem item) async {
    if (item.type != EditorItemType.link) return;
    final isInternal = await _askLinkType();
    if (isInternal == null || !mounted) return;

    final label = await _textDialog(
      initialText: item.text ?? '',
      title: '링크 표시 텍스트',
      maxLines: 1,
    );
    if (label == null || !mounted) return;

    if (isInternal) {
      final targetPage = await _askPageNumber(initial: item.linkTargetPage);
      if (targetPage == null) return;
      _commit();
      setState(() {
        item.text = label.isEmpty ? '${targetPage + 1}페이지로 이동' : label;
        item.linkTargetPage = targetPage;
        item.linkUrl = null;
      });
      return;
    }

    final url = await _textDialog(
      initialText: item.linkUrl ?? '',
      title: '링크 URL',
      maxLines: 1,
    );
    if (url == null || url.isEmpty || !mounted) return;
    _commit();
    setState(() {
      item.text = label.isEmpty ? url : label;
      item.linkUrl = url;
      item.linkTargetPage = null;
    });
  }

  Future<List<PdfTextRun>> _extractRunsForCurrentPage() async {
    List<PdfNativePage> nativePages;
    try {
      nativePages = await PdfNativeTextService.extractRuns(_currentFile);
    } catch (_) {
      nativePages = const [];
    }
    return nativePages
        .where((page) => page.pageIndex == _pageIndex)
        .expand((page) => page.runs)
        .where((run) => run.text.trim().isNotEmpty)
        .toList();
  }

  /// Toolbar toggle for direct on-page text editing: once active, tapping
  /// a piece of text on the page itself edits it in place instead of
  /// picking it out of a flat list first — much faster than hunting
  /// through a long list when a page has a lot of text. The list picker
  /// still exists as a fallback for the rare ambiguous tap (several runs
  /// close together) or when nothing extractable was found under the tap.
  Future<void> _toggleTextEditTapMode() async {
    if (_textEditTapMode) {
      setState(() => _textEditTapMode = false);
      return;
    }
    if (_pages.isEmpty) return;
    if (!_shownNativeEditNotice) {
      final proceed = await showExperimentalPdfNotice(
        context,
        featureName: '원본 폰트 유지 텍스트 편집',
      );
      if (!mounted || !proceed) return;
      _shownNativeEditNotice = true;
    }
    setState(() => _recognizing = true);
    final runsOnPage = await _extractRunsForCurrentPage();
    if (!mounted) return;
    setState(() => _recognizing = false);

    if (runsOnPage.isEmpty) {
      await _recognizeExistingText();
      return;
    }

    setState(() {
      _textEditRunsOnPage = runsOnPage;
      _textEditTapMode = true;
      _selectedId = null;
      _activeGizmoMode = null;
      _drawingMode = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('수정할 텍스트를 화면에서 바로 탭하세요.')),
    );
  }

  /// Hit-tests [tapNormX]/[tapNormY] (fraction of page width/height,
  /// top-left origin — same convention as [EditorItem]) against the
  /// currently cached text runs, using each run's approximate on-page
  /// bounding box (real glyph-level layout isn't tracked, so this is an
  /// axis-aligned estimate from the run's origin, font size, and advance
  /// widths). Zero matches re-runs OCR-based recognition as a fallback;
  /// more than one shows a short candidate list instead of guessing.
  Future<void> _handlePageTapForTextEdit(
    double tapNormX,
    double tapNormY,
  ) async {
    final page = _pages[_pageIndex];
    const tolerance = 0.01;
    final candidates = _textEditRunsOnPage.where((run) {
      final box = _approxRunBoxNormalized(run, page);
      return tapNormX >= box.left - tolerance &&
          tapNormX <= box.right + tolerance &&
          tapNormY >= box.top - tolerance &&
          tapNormY <= box.bottom + tolerance;
    }).toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('탭한 위치에서 편집 가능한 텍스트를 찾지 못했습니다.')),
      );
      return;
    }

    final run = candidates.length == 1
        ? candidates.single
        : await showModalBottomSheet<PdfTextRun>(
            context: context,
            isScrollControlled: true,
            builder: (sheetContext) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      '탭한 위치에 겹치는 텍스트가 여러 개입니다. 수정할 텍스트를 선택하세요.',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: candidates.length,
                      itemBuilder: (_, index) => ListTile(
                        title: Text(candidates[index].text),
                        onTap: () => Navigator.pop(sheetContext, candidates[index]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
    if (run == null || !mounted) return;
    await _editRun(run);
  }

  ({double left, double top, double right, double bottom})
  _approxRunBoxNormalized(PdfTextRun run, RenderedPdfPage page) {
    final scale = run.ctm.yScale;
    final glyphWidth = run.text.runes.fold<double>(
      0,
      (total, rune) => total + run.font.widthOf(String.fromCharCode(rune)),
    );
    final extraSpacing =
        math.max(0, run.text.runes.length - 1) * run.charSpacing * scale;
    final width =
        glyphWidth / 1000 * run.fontSize * scale * (run.horizScalePercent / 100) +
        extraSpacing;
    final height = run.fontSize * scale;

    final leftPdf = run.originX;
    final bottomPdf = run.originY - height * 0.2;
    final topPdf = bottomPdf + height * 1.2;
    final rightPdf = leftPdf + math.max(width, height * 0.5);

    return (
      left: leftPdf / page.width,
      top: 1 - topPdf / page.height,
      right: rightPdf / page.width,
      bottom: 1 - bottomPdf / page.height,
    );
  }

  /// Shared replacement flow for a single text run — used by both the
  /// on-page tap-to-edit path and (for now) nothing else, but kept
  /// separate from the tap-hit-testing logic above since the two concerns
  /// (finding the run vs. editing it) can fail independently.
  Future<void> _editRun(PdfTextRun run) async {
    final newText = await _textDialog(initialText: run.text, title: '텍스트 수정');
    if (newText == null || newText.isEmpty || newText == run.text) return;

    // Every re-application (initial + manual nudges) is applied fresh
    // against the file as it was *before* this edit — replaceRunText
    // locates the run by its original byte offsets, which stop being
    // valid the moment that content stream is rewritten once.
    final baseFile = _currentFile;
    final adjustment = _RunAdjustment(
      horizScalePercent: run.horizScalePercent.clamp(50, 150).toDouble(),
    );
    final applied = await _applyRunReplacement(run, newText, baseFile, adjustment);
    if (applied == null || !mounted) return;

    await _adjustRunPositionSheet(run, newText, baseFile, adjustment);
  }

  /// Runs [PdfNativeTextService.replaceRunText] and folds in the shared
  /// success/failure handling (snackbars, OCR fallback, page reload) used
  /// by both the initial edit and any manual nudges.
  Future<({bool usedFallbackFont})?> _applyRunReplacement(
    PdfTextRun run,
    String newText,
    File baseFile,
    _RunAdjustment adjustment,
  ) async {
    setState(() => _recognizing = true);
    try {
      final result = await PdfNativeTextService.replaceRunText(
        file: baseFile,
        pageIndex: _pageIndex,
        run: run,
        newText: newText,
        manualOffsetX: adjustment.offsetX,
        manualOffsetY: adjustment.offsetY,
        manualHorizScalePercent: adjustment.horizScalePercent,
      );
      _currentFile = result.file;
      _hasNativeTextEdits = true;
      // The edited run's own content stream was rewritten, so any other
      // cached run offsets into that same stream are now stale — refresh
      // before the next tap rather than risk editing against dead bytes.
      final refreshedRuns = await _extractRunsForCurrentPage();
      await _load();
      if (mounted) {
        setState(() => _textEditRunsOnPage = refreshedRuns);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.usedFallbackFont
                  ? '원본에 없는 글자가 있어 대체 폰트로 텍스트를 수정했습니다.'
                  : '원본 폰트를 유지한 채 텍스트를 수정했습니다.',
            ),
          ),
        );
      }
      return (usedFallbackFont: result.usedFallbackFont);
    } on PdfRunNotEditableException {
      // Neither the original font nor the bundled fallback font can
      // represent this text (a genuine rarity) — fall back to the OCR
      // overlay, which can draw arbitrary text using the app's own UI
      // font instead of a real embedded PDF font.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('이 글자는 표현할 수 있는 폰트가 없어 OCR 방식으로 전환합니다.'),
          ),
        );
      }
      setState(() => _textEditTapMode = false);
      await _recognizeExistingText();
      return null;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('텍스트 수정 실패: $error')));
      }
      return null;
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  /// Follow-up bottom sheet for manually fine-tuning a just-applied native
  /// text edit: nudge left/right/up/down, and a letter-spacing (Tz)
  /// slider — nothing here is automatic, since auto-condensing the text
  /// behind the user's back turned out to be more surprising than
  /// helpful. Every change re-applies the edit fresh from [baseFile] so
  /// adjustments don't compound on top of a moving target.
  Future<void> _adjustRunPositionSheet(
    PdfTextRun run,
    String newText,
    File baseFile,
    _RunAdjustment adjustment,
  ) async {
    const step = 2.0;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> apply() async {
            setSheetState(() {});
            await _applyRunReplacement(run, newText, baseFile, adjustment);
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '위치와 글자 간격을 직접 조정할 수 있습니다.',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        tooltip: '왼쪽으로',
                        onPressed: () {
                          adjustment.offsetX -= step;
                          apply();
                        },
                        icon: const Icon(Icons.chevron_left),
                      ),
                      IconButton.filledTonal(
                        tooltip: '오른쪽으로',
                        onPressed: () {
                          adjustment.offsetX += step;
                          apply();
                        },
                        icon: const Icon(Icons.chevron_right),
                      ),
                      const SizedBox(width: 24),
                      IconButton.filledTonal(
                        tooltip: '위로',
                        onPressed: () {
                          adjustment.offsetY += step;
                          apply();
                        },
                        icon: const Icon(Icons.keyboard_arrow_up),
                      ),
                      IconButton.filledTonal(
                        tooltip: '아래로',
                        onPressed: () {
                          adjustment.offsetY -= step;
                          apply();
                        },
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.text_fields, size: 20),
                      Expanded(
                        child: Slider(
                          min: 50,
                          max: 150,
                          divisions: 100,
                          label: '${adjustment.horizScalePercent.round()}%',
                          value: adjustment.horizScalePercent,
                          onChanged: (value) {
                            adjustment.horizScalePercent = value;
                            setSheetState(() {});
                          },
                          onChangeEnd: (_) => apply(),
                        ),
                      ),
                      Text('${adjustment.horizScalePercent.round()}%'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('완료'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _recognizeExistingText() async {
    if (_pages.isEmpty) return;
    setState(() => _recognizing = true);
    List<OcrTextBlock> blocks;
    try {
      blocks = await OcrService.recognizeText(_pages[_pageIndex].bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('텍스트 인식 실패: $error')));
      }
      return;
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
    if (!mounted) return;
    if (blocks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이 페이지에서 텍스트를 찾지 못했습니다.')));
      return;
    }

    final selected = await showModalBottomSheet<OcrTextBlock>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, scrollController) => SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '수정할 텍스트를 선택하세요',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: blocks.length,
                  itemBuilder: (_, index) => ListTile(
                    title: Text(blocks[index].text),
                    onTap: () => Navigator.pop(sheetContext, blocks[index]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;

    final newText = await _textDialog(
      initialText: selected.text,
      title: '텍스트 수정',
    );
    if (newText == null || newText.isEmpty) return;

    const padding = 0.006;
    final maskX = (selected.x - padding).clamp(0.0, 1.0);
    final maskY = (selected.y - padding).clamp(0.0, 1.0);
    final maskWidth = math.min(selected.width + padding * 2, 1.0 - maskX);
    final maskHeight = math.min(selected.height + padding * 2, 1.0 - maskY);

    _commit();
    setState(() {
      final mask = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.rect,
        pageIndex: _pageIndex,
        x: maskX,
        y: maskY,
        width: maskWidth,
        height: maskHeight,
        colorValue: 0xFFFFFFFF,
      );
      final page = _pages[_pageIndex];
      final replacement = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.text,
        pageIndex: _pageIndex,
        x: selected.x,
        y: selected.y,
        width: selected.width,
        height: selected.height,
        text: newText,
        fontSize: (selected.height * page.height * 0.72)
            .clamp(8.0, 96.0)
            .toDouble(),
      );
      _items
        ..add(mask)
        ..add(replacement);
      _selectedId = replacement.id;
      _drawingMode = false;
    });
  }

  void _addMemo() {
    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.memo,
        pageIndex: _pageIndex,
        x: 0.2,
        y: 0.25,
        width: 0.3,
        height: 0.15,
        text: '메모를 입력하세요',
        colorValue: 0xFFFFF59D,
      );
      _items.add(item);
      _selectedId = item.id;
      _drawingMode = false;
    });
  }

  Future<void> _addLink() async {
    final isInternal = await _askLinkType();
    if (isInternal == null || !mounted) return;

    final label = await _textDialog(title: '링크 표시 텍스트', maxLines: 1);
    if (label == null || !mounted) return;

    String text;
    String? url;
    int? targetPage;
    if (isInternal) {
      final page = await _askPageNumber();
      if (page == null) return;
      targetPage = page;
      text = label.isEmpty ? '${page + 1}페이지로 이동' : label;
    } else {
      final input = await _textDialog(title: '링크 URL (https://...)', maxLines: 1);
      if (input == null || input.isEmpty || !mounted) return;
      url = input;
      text = label.isEmpty ? input : label;
    }

    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.link,
        pageIndex: _pageIndex,
        x: 0.15,
        y: 0.2,
        width: 0.4,
        height: 0.06,
        text: text,
        linkUrl: url,
        linkTargetPage: targetPage,
        fontSize: 16,
      );
      _items.add(item);
      _selectedId = item.id;
      _drawingMode = false;
    });
  }

  void _addShape() {
    _commit();
    setState(() {
      final item = EditorItem(
        id: _uuid.v4(),
        type: EditorItemType.rect,
        pageIndex: _pageIndex,
        x: 0.2,
        y: 0.25,
        width: 0.25,
        height: 0.15,
        colorValue: 0x80FFEB3B,
      );
      _items.add(item);
      _selectedId = item.id;
      _drawingMode = false;
    });
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
    final bytes = await showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _SignatureSheet(),
    );
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
      _itemContentKeys.remove(_selectedId);
      _selectedId = null;
      _activeGizmoMode = null;
    });
  }

  Future<void> _confirmDeleteSelected() async {
    if (_selectedId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('개체를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) _deleteSelected();
  }

  GlobalKey _contentKeyFor(String itemId) =>
      _itemContentKeys.putIfAbsent(itemId, () => GlobalKey());

  /// Global (screen-space) center of the item's rotation pivot, unaffected
  /// by the item's own [EditorItem.rotation] since [Transform.rotate]
  /// rotates about its own center by default.
  Offset? _itemGlobalCenter(EditorItem item) {
    final box =
        _contentKeyFor(item.id).currentContext?.findRenderObject()
            as RenderBox?;
    if (box == null || !box.attached) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  void _copySelected() {
    final item = _selectedItem;
    if (item == null) return;
    setState(() => _clipboard = item.copy());
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('개체를 복사했습니다.')));
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
    if (item == null) {
      // No item selected yet: if the user is mid-drawing-mode, treat
      // this as choosing the pen color for the *next* stroke rather
      // than a no-op — the color palette is already shown during
      // drawing mode, so it should actually do something.
      if (_drawingMode) setState(() => _drawColor = color);
      return;
    }
    _commit();
    setState(() => item.colorValue = color.toARGB32());
  }

  void _changeSelectedSize(double factor) {
    final item = _selectedItem;
    if (item == null) {
      if (_drawingMode) {
        setState(() {
          _drawStrokeWidth = (_drawStrokeWidth * factor)
              .clamp(1.0, 16.0)
              .toDouble();
        });
      }
      return;
    }
    _commit();
    setState(() {
      if (item.type == EditorItemType.text) {
        item.fontSize = (item.fontSize * factor).clamp(8.0, 96.0).toDouble();
      } else if (item.type == EditorItemType.drawing) {
        item.strokeWidth = (item.strokeWidth * factor)
            .clamp(1.0, 16.0)
            .toDouble();
      } else {
        item.width = (item.width * factor)
            .clamp(0.045, 1.0 - item.x)
            .toDouble();
        item.height = (item.height * factor)
            .clamp(0.035, 1.0 - item.y)
            .toDouble();
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
    final dx = (details.localPosition.dx / size.width)
        .clamp(0.0, 1.0)
        .toDouble();
    final dy = (details.localPosition.dy / size.height)
        .clamp(0.0, 1.0)
        .toDouble();
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
      strokeWidth: _drawStrokeWidth,
      colorValue: _drawColor.toARGB32(),
    );
    setState(() {
      _items.add(item);
      _selectedId = item.id;
      _activeStroke = [];
    });
  }

  Future<File?> _exportFile() async {
    if (_pages.isEmpty) return null;
    // If the only change this session was one or more native text edits
    // (no stamps/signatures/drawing overlays added), save the natively
    // edited file directly — it's still a real PDF with the original
    // fonts/structure intact. Routing it through the raster rebuild below
    // would flatten it to an image like everything else and throw that
    // fidelity away for no reason.
    if (_hasNativeTextEdits && _items.isEmpty) {
      return _currentFile;
    }
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

  String get _outputName {
    final base = widget.fileName.replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '');
    return '${base}_edited.pdf';
  }

  Future<void> _savePdf() async {
    try {
      final file = await _exportFile();
      if (file == null) return;
      final saved = await AndroidFileService.savePdf(
        sourcePath: file.path,
        fileName: _outputName,
      );
      if (saved && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('PDF를 저장했습니다.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF 저장 실패: $error')));
      }
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

  void _resetView() {
    _transformController.value = Matrix4.identity();
    if (_zoomScale != 1) setState(() => _zoomScale = 1);
  }

  Widget _zoomIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final color = Theme.of(context).colorScheme.onInverseSurface;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: onPressed == null ? color.withValues(alpha: 0.35) : color),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      splashRadius: 18,
    );
  }

  void _toggleZoom() {
    if (_zoomScale > 1.05) {
      _resetView();
      return;
    }
    _transformController.value = Matrix4.diagonal3Values(2.0, 2.0, 1.0);
    setState(() => _zoomScale = 2.0);
  }

  static const double _minZoomScale = 1.0;
  static const double _maxZoomScale = 6.0;

  /// Zoom in/out by [delta] around the viewport center — same
  /// re-center-on-zoom simplification [_toggleZoom] already uses, rather
  /// than preserving whatever point was under a finger (there isn't one
  /// for a button tap anyway).
  void _zoomByButton(double delta) {
    final nextScale = (_zoomScale + delta).clamp(_minZoomScale, _maxZoomScale);
    if (nextScale == _minZoomScale) {
      _resetView();
      return;
    }
    _transformController.value = Matrix4.diagonal3Values(
      nextScale,
      nextScale,
      1.0,
    );
    setState(() => _zoomScale = nextScale.toDouble());
  }

  void _updateToolbarIndicator() {
    if (!_objectToolbarController.hasClients) return;
    final position = _objectToolbarController.position;
    final show =
        position.maxScrollExtent > 8 &&
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
                    physics:
                        _drawingMode || _selectedId != null || _zoomScale > 1.01
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    itemCount: _pages.length,
                    onPageChanged: (index) {
                      setState(() {
                        _pageIndex = index;
                        _selectedId = null;
                        _activeGizmoMode = null;
                        _textEditTapMode = false;
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
              Icons.find_replace,
              _textEditTapMode ? '편집 종료' : '텍스트 편집',
              _recognizing ? () {} : _toggleTextEditTapMode,
              selected: _textEditTapMode,
            ),
            _insertTool(
              _drawingMode ? Icons.edit_off : Icons.draw,
              _drawingMode ? '필기 종료' : '자유 필기',
              () {
                setState(() {
                  _drawingMode = !_drawingMode;
                  _selectedId = null;
                  _activeGizmoMode = null;
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
    final supportsColor =
        selected == null ||
        selected.type == EditorItemType.text ||
        selected.type == EditorItemType.check ||
        selected.type == EditorItemType.drawing ||
        selected.type == EditorItemType.rect;

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
                          onTap: selected == null && !_drawingMode
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
                                color:
                                    (selected?.colorValue ??
                                            (_drawingMode
                                                ? _drawColor.toARGB32()
                                                : null)) ==
                                        color.toARGB32()
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
                  if (selected == null && _drawingMode) ...[
                    const VerticalDivider(),
                    _toolbarAction(
                      icon: Icons.remove,
                      label: '얇게',
                      onTap: () => _changeSelectedSize(0.9),
                    ),
                    _toolbarAction(
                      icon: Icons.add,
                      label: '굵게',
                      onTap: () => _changeSelectedSize(1.1),
                    ),
                  ],
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
                    if (selected.type == EditorItemType.text ||
                        selected.type == EditorItemType.memo)
                      _toolbarAction(
                        icon: Icons.edit,
                        label: '수정',
                        onTap: () => _editText(selected),
                      ),
                    if (selected.type == EditorItemType.link) ...[
                      _toolbarAction(
                        icon: Icons.edit,
                        label: '수정',
                        onTap: () => _editLink(selected),
                      ),
                      _toolbarAction(
                        icon: Icons.open_in_new,
                        label: '열기',
                        onTap: () => _openLink(
                          PdfLinkAnnotation(
                            pageIndex: selected.pageIndex,
                            rectX: 0,
                            rectY: 0,
                            rectWidth: 0,
                            rectHeight: 0,
                            uri: selected.linkUrl,
                            destPageIndex: selected.linkTargetPage,
                          ),
                        ),
                      ),
                    ],
                    _toolbarAction(
                      icon: Icons.delete_outline,
                      label: '삭제',
                      onTap: _confirmDeleteSelected,
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
                          Theme.of(
                            context,
                          ).colorScheme.surface.withValues(alpha: 0),
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
          separatorBuilder: (context, index) => const SizedBox(width: 8),
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
              leading: const Icon(Icons.crop_square),
              title: const Text('도형 추가'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addShape();
              },
            ),
            ListTile(
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: const Text('메모 추가'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addMemo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('링크 추가'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addLink();
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
        const margin = 10.0;
        final availableWidth = math.max(1.0, constraints.maxWidth - margin * 2);
        final availableHeight = math.max(
          1.0,
          constraints.maxHeight - margin * 2,
        );
        var pageWidth = availableWidth;
        var pageHeight = pageWidth / page.aspectRatio;
        if (pageHeight > availableHeight) {
          pageHeight = availableHeight;
          pageWidth = pageHeight * page.aspectRatio;
        }
        final pageSize = Size(pageWidth, pageHeight);
        final pageItems = _items
            .where((item) => item.pageIndex == index)
            .toList();

        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _transformController,
                constrained: true,
                alignment: Alignment.center,
                clipBehavior: Clip.hardEdge,
                boundaryMargin: const EdgeInsets.all(300),
                minScale: 1,
                maxScale: 6,
                // Panning must be off while an item is selected — otherwise
                // dragging the item to move/rotate/resize it also drags the
                // InteractiveViewer underneath it, since both gesture
                // detectors sit in the same hit-test chain and Flutter
                // recognizes pan gestures on both simultaneously.
                panEnabled: !_drawingMode && _selectedId == null,
                scaleEnabled: !_drawingMode && _selectedId == null,
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
                      onTapUp: (details) {
                        if (_drawingMode) return;
                        if (_textEditTapMode) {
                          _handlePageTapForTextEdit(
                            details.localPosition.dx / pageSize.width,
                            details.localPosition.dy / pageSize.height,
                          );
                          return;
                        }
                        setState(() {
                          _selectedId = null;
                          _activeGizmoMode = null;
                        });
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
                          if (!_drawingMode && !_textEditTapMode)
                            ..._links
                                .where((link) => link.pageIndex == index)
                                .map((link) => _linkOverlay(link, pageSize)),
                          ...pageItems.map(
                            (item) => _itemWidget(item, pageSize),
                          ),
                          if (_activeStroke.isNotEmpty)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _StrokePainter(
                                    _activeStroke,
                                    _drawColor,
                                    _drawStrokeWidth,
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
                          if (_exporting || _recognizing)
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
                color: Theme.of(
                  context,
                ).colorScheme.inverseSurface.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(18),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _zoomIconButton(
                      icon: Icons.remove,
                      tooltip: '축소',
                      onPressed: _zoomScale <= _minZoomScale
                          ? null
                          : () => _zoomByButton(-0.5),
                    ),
                    InkWell(
                      onTap: _resetView,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '${(_zoomScale * 100).round()}%',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onInverseSurface,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    _zoomIconButton(
                      icon: Icons.add,
                      tooltip: '확대',
                      onPressed: _zoomScale >= _maxZoomScale
                          ? null
                          : () => _zoomByButton(0.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _linkOverlay(PdfLinkAnnotation link, Size pageSize) {
    return Positioned(
      left: link.rectX * pageSize.width,
      top: link.rectY * pageSize.height,
      width: link.rectWidth * pageSize.width,
      height: link.rectHeight * pageSize.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openLink(link),
      ),
    );
  }

  Future<void> _openLink(PdfLinkAnnotation link) async {
    final destPageIndex = link.destPageIndex;
    if (destPageIndex != null) {
      if (destPageIndex < 0 || destPageIndex >= _pages.length) return;
      setState(() {
        _selectedId = null;
        _activeGizmoMode = null;
      });
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          destPageIndex,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        );
      }
      return;
    }
    final uri = link.uri;
    if (uri == null) return;
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return;
    if (!await launchUrl(parsed, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('링크를 열 수 없습니다.')));
      }
    }
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
    } else if (item.type == EditorItemType.rect) {
      content = ColoredBox(color: Color(item.colorValue));
    } else if (item.type == EditorItemType.memo) {
      content = Container(
        color: Color(item.colorValue),
        padding: const EdgeInsets.all(6),
        child: Text(
          item.text ?? '',
          style: const TextStyle(fontSize: 12, color: Colors.black87),
        ),
      );
    } else if (item.type == EditorItemType.link) {
      content = Align(
        alignment: Alignment.topLeft,
        child: Text(
          item.text ?? item.linkUrl ?? '',
          style: TextStyle(
            fontSize: item.fontSize,
            color: Colors.blue,
            decoration: TextDecoration.underline,
          ),
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
          key: _contentKeyFor(item.id),
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!_drawingMode) {
                    setState(() {
                      if (_selectedId != item.id) _activeGizmoMode = null;
                      _selectedId = item.id;
                      _showMoreToolsIndicator = true;
                    });
                    if (_objectToolbarController.hasClients) {
                      _objectToolbarController.jumpTo(0);
                    }
                  }
                },
                onDoubleTap: switch (item.type) {
                  EditorItemType.text ||
                  EditorItemType.memo => () => _editText(item),
                  EditorItemType.link => () => _editLink(item),
                  _ => null,
                },
                onPanStart: (details) {
                  if (_drawingMode) return;
                  _commit();
                  if (selected && _activeGizmoMode == 'rotate') {
                    final center = _itemGlobalCenter(item);
                    if (center != null) {
                      final vector = details.globalPosition - center;
                      _rotateStartAngle = math.atan2(vector.dy, vector.dx);
                      _rotateStartRotation = item.rotation;
                    }
                    return;
                  }
                  setState(() => _selectedId = item.id);
                },
                onPanUpdate: (details) {
                  if (_drawingMode) return;
                  if (selected && _activeGizmoMode == 'rotate') {
                    final startAngle = _rotateStartAngle;
                    final center = _itemGlobalCenter(item);
                    if (startAngle == null || center == null) return;
                    final vector = details.globalPosition - center;
                    final currentAngle = math.atan2(vector.dy, vector.dx);
                    setState(() {
                      item.rotation =
                          _rotateStartRotation + (currentAngle - startAngle);
                    });
                    return;
                  }
                  if (selected && _activeGizmoMode == 'resize') {
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
                    return;
                  }
                  setState(() {
                    item.x = (item.x + details.delta.dx / pageSize.width)
                        .clamp(0.0, 1.0 - item.width)
                        .toDouble();
                    item.y = (item.y + details.delta.dy / pageSize.height)
                        .clamp(0.0, 1.0 - item.height)
                        .toDouble();
                  });
                },
                onPanEnd: (_) => _rotateStartAngle = null,
                onPanCancel: () => _rotateStartAngle = null,
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
                top: -58 * _inverseZoom,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        _activeGizmoMode = _activeGizmoMode == 'rotate'
                            ? null
                            : 'rotate';
                      });
                    },
                    child: Transform.scale(
                      scale: _inverseZoom,
                      child: _handle(
                        icon: Icons.rotate_right,
                        tooltip: _activeGizmoMode == 'rotate'
                            ? '회전 모드 종료'
                            : '탭하여 회전 모드 진입 후 좌우로 드래그',
                        active: _activeGizmoMode == 'rotate',
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -25 * _inverseZoom,
                bottom: -25 * _inverseZoom,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() {
                      _activeGizmoMode = _activeGizmoMode == 'resize'
                          ? null
                          : 'resize';
                    });
                  },
                  child: Transform.scale(
                    scale: _inverseZoom,
                    child: _handle(
                      icon: Icons.open_in_full,
                      tooltip: _activeGizmoMode == 'resize'
                          ? '크기 조절 모드 종료'
                          : '탭하여 크기 조절 모드 진입 후 드래그',
                      active: _activeGizmoMode == 'resize',
                    ),
                  ),
                ),
              ),
              Positioned(
                left: -25 * _inverseZoom,
                top: -25 * _inverseZoom,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _confirmDeleteSelected,
                  child: Transform.scale(
                    scale: _inverseZoom,
                    child: _handle(
                      icon: Icons.close,
                      tooltip: '삭제',
                      danger: true,
                    ),
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

/// Mutable holder for the manual x/y/letter-spacing nudges applied to a
/// single in-progress native text-run edit (see [_PdfEditorScreenState._editRun]).
class _RunAdjustment {
  _RunAdjustment({this.horizScalePercent = 100});
  double offsetX = 0;
  double offsetY = 0;
  double horizScalePercent;
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

/// Signature pad with pen color/thickness controls. [SignatureController]'s
/// `penColor`/`penStrokeWidth` are read-only after construction, so
/// changing style mid-signature means rebuilding the controller — losing
/// whatever was already drawn. Acceptable here (style changes are a rare,
/// deliberate action before/between strokes, not something users do
/// mid-stroke), and far simpler than maintaining a custom stroke-recording
/// layer just to preserve content across a controller swap.
class _SignatureSheet extends StatefulWidget {
  const _SignatureSheet();

  @override
  State<_SignatureSheet> createState() => _SignatureSheetState();
}

class _SignatureSheetState extends State<_SignatureSheet> {
  static const _palette = <Color>[
    Colors.black,
    Color(0xFFEF4444),
    Color(0xFF3B82F6),
    Color(0xFF22C55E),
    Color(0xFF8B5CF6),
  ];

  Color _color = Colors.black;
  double _strokeWidth = 3;
  late SignatureController _controller = _buildController();

  SignatureController _buildController() => SignatureController(
    penStrokeWidth: _strokeWidth,
    penColor: _color,
    exportBackgroundColor: Colors.transparent,
  );

  void _updateStyle({Color? color, double? strokeWidth}) {
    setState(() {
      _color = color ?? _color;
      _strokeWidth = strokeWidth ?? _strokeWidth;
      _controller.dispose();
      _controller = _buildController();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
            Row(
              children: [
                for (final color in _palette)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      onTap: () => _updateStyle(color: color),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _color == color
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white,
                            width: 3,
                          ),
                          boxShadow: const [
                            BoxShadow(color: Color(0x33000000), blurRadius: 2),
                          ],
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: '얇게',
                  icon: const Icon(Icons.remove),
                  onPressed: () => _updateStyle(
                    strokeWidth: (_strokeWidth - 1).clamp(1.0, 10.0),
                  ),
                ),
                Text('${_strokeWidth.round()}'),
                IconButton(
                  tooltip: '굵게',
                  icon: const Icon(Icons.add),
                  onPressed: () => _updateStyle(
                    strokeWidth: (_strokeWidth + 1).clamp(1.0, 10.0),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: Signature(
                controller: _controller,
                backgroundColor: Colors.white,
              ),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: _controller.clear,
                  child: const Text('지우기'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () async {
                    final imageBytes = await _controller.toPngBytes();
                    if (context.mounted && imageBytes != null) {
                      Navigator.pop(context, imageBytes);
                    }
                  },
                  child: const Text('추가'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
