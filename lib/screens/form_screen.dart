import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/android_file_service.dart';
import '../services/pdf_native/pdf_form_fields.dart';
import '../services/pdf_native/pdf_form_service.dart';
import '../services/pdf_service.dart';

enum _PlacementMode { text, checkbox }

/// Fills existing AcroForm fields (kept as real, live, still-editable
/// form fields — not flattened to static overlay text/images like the
/// rest of this app's editor) and lets the user add brand-new text/
/// checkbox fields to any PDF. See pdf_native/pdf_form_fields.dart and
/// pdf_form_service.dart for the underlying read/write implementation.
class FormScreen extends StatefulWidget {
  const FormScreen({super.key, required this.file, required this.fileName});

  final File file;
  final String fileName;

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  late File _currentFile = widget.file;
  List<RenderedPdfPage> _pages = [];
  List<PdfFormField> _fields = [];
  bool _loading = true;
  bool _busy = false;
  int _pageIndex = 0;
  _PlacementMode? _placementMode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pages = await PdfService.renderAllPages(_currentFile);
      final fields = await PdfFormService.extractFields(_currentFile);
      if (mounted) {
        setState(() {
          _pages = pages;
          _fields = fields;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF 로딩 실패: $error')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _promptText({
    required String title,
    String initialText = '',
  }) async {
    final controller = TextEditingController(text: initialText);
    controller.selection = TextSelection.fromPosition(
      TextPosition(offset: controller.text.length),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _runFieldEdit(Future<File> Function() action, String failureMessage) async {
    setState(() => _busy = true);
    try {
      final edited = await action();
      _currentFile = edited;
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$failureMessage: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onFieldTap(PdfFormField field) async {
    if (_placementMode != null) return;

    switch (field.type) {
      case PdfFormFieldType.checkbox:
        await _runFieldEdit(
          () => PdfFormService.toggleCheckbox(
            file: _currentFile,
            field: field,
            checked: !field.checked,
          ),
          '체크박스 변경 실패',
        );
      case PdfFormFieldType.radio:
        if (field.checked) return; // already selected
        await _runFieldEdit(
          () => PdfFormService.selectRadioOption(file: _currentFile, selected: field),
          '라디오 버튼 선택 실패',
        );
      case PdfFormFieldType.choice:
        final choice = await showModalBottomSheet<String>(
          context: context,
          builder: (sheetContext) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final option in field.options)
                  ListTile(
                    title: Text(option),
                    trailing: option == field.value
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(sheetContext, option),
                  ),
              ],
            ),
          ),
        );
        if (choice == null || choice == field.value || !mounted) return;
        await _runFieldEdit(
          () => PdfFormService.setTextFieldValue(
            file: _currentFile,
            field: field,
            newValue: choice,
          ),
          '선택 항목 저장 실패',
        );
      case PdfFormFieldType.text:
        final newValue = await _promptText(
          title: field.name.isEmpty ? '값 입력' : field.name,
          initialText: field.value,
        );
        if (newValue == null || newValue == field.value || !mounted) return;
        await _runFieldEdit(
          () => PdfFormService.setTextFieldValue(
            file: _currentFile,
            field: field,
            newValue: newValue,
          ),
          '입력란 저장 실패',
        );
    }
  }

  Future<void> _onPageTapUp(TapUpDetails details, Size pageSize) async {
    final mode = _placementMode;
    if (mode == null) return;
    final normX = (details.localPosition.dx / pageSize.width).clamp(0.0, 0.9);
    final normY = (details.localPosition.dy / pageSize.height).clamp(0.0, 0.9);

    final name = await _promptText(
      title: mode == _PlacementMode.text ? '텍스트 필드 이름' : '체크박스 이름',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      final edited = mode == _PlacementMode.text
          ? await PdfFormService.addTextField(
              file: _currentFile,
              pageIndex: _pageIndex,
              name: name.trim(),
              normX: normX,
              normY: normY,
              normWidth: 0.35,
              normHeight: 0.045,
            )
          : await PdfFormService.addCheckboxField(
              file: _currentFile,
              pageIndex: _pageIndex,
              name: name.trim(),
              normX: normX,
              normY: normY,
              normWidth: 0.04,
              normHeight: 0.03,
            );
      _currentFile = edited;
      setState(() => _placementMode = null);
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('필드 추가 실패: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final saved = await AndroidFileService.savePdf(
      sourcePath: _currentFile.path,
      fileName:
          '${widget.fileName.replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '')}_form.pdf',
    );
    if (saved && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('양식 PDF를 저장했습니다.')));
    }
  }

  Future<void> _share() async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(_currentFile.path)], subject: widget.fileName),
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
            tooltip: '저장',
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
          ),
          IconButton(
            tooltip: '공유',
            onPressed: _busy ? null : _share,
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _pages.isEmpty
          ? const Center(child: Text('표시할 페이지가 없습니다.'))
          : Stack(
              children: [
                PageView.builder(
                  itemCount: _pages.length,
                  onPageChanged: (index) => setState(() => _pageIndex = index),
                  itemBuilder: (_, index) => _buildPage(index),
                ),
                if (_placementMode != null)
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: Material(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _placementMode == _PlacementMode.text
                                    ? '텍스트 필드를 놓을 위치를 탭하세요'
                                    : '체크박스를 놓을 위치를 탭하세요',
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _placementMode = null),
                              child: const Text('취소'),
                            ),
                          ],
                        ),
                      ),
                    ),
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
      bottomNavigationBar: _pages.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(
                              () => _placementMode = _PlacementMode.text,
                            ),
                      icon: const Icon(Icons.text_fields),
                      label: const Text('텍스트 필드 추가'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(
                              () => _placementMode = _PlacementMode.checkbox,
                            ),
                      icon: const Icon(Icons.check_box_outlined),
                      label: const Text('체크박스 추가'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildPage(int index) {
    final page = _pages[index];
    final pageFields = _fields
        .where((field) => field.pageIndex == index)
        .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        const margin = 10.0;
        final availableWidth = constraints.maxWidth - margin * 2;
        final availableHeight = constraints.maxHeight - margin * 2;
        var pageWidth = availableWidth;
        var pageHeight = pageWidth / page.aspectRatio;
        if (pageHeight > availableHeight) {
          pageHeight = availableHeight;
          pageWidth = pageHeight * page.aspectRatio;
        }
        final pageSize = Size(pageWidth, pageHeight);

        return Center(
          child: SizedBox(
            width: pageWidth,
            height: pageHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _onPageTapUp(details, pageSize),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(blurRadius: 8, color: Color(0x33000000)),
                        ],
                      ),
                      child: Image.memory(page.bytes, fit: BoxFit.fill),
                    ),
                  ),
                  for (final field in pageFields)
                    Positioned(
                      left: field.normX * pageWidth,
                      top: field.normY * pageHeight,
                      width: field.normWidth * pageWidth,
                      height: field.normHeight * pageHeight,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _onFieldTap(field),
                        child: _fieldContent(field),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _fieldContent(PdfFormField field) {
    final isOnState =
        field.type == PdfFormFieldType.checkbox || field.type == PdfFormFieldType.radio;
    final color = isOnState
        ? (field.checked ? Colors.green : Colors.blue)
        : Colors.blue;
    final isRadio = field.type == PdfFormFieldType.radio;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color, width: 1.5),
        shape: isRadio ? BoxShape.circle : BoxShape.rectangle,
      ),
      child: switch (field.type) {
        PdfFormFieldType.checkbox =>
          field.checked
              ? const Icon(Icons.check, size: 16, color: Colors.green)
              : null,
        PdfFormFieldType.radio =>
          field.checked
              ? const Center(
                  child: Icon(Icons.circle, size: 10, color: Colors.green),
                )
              : null,
        PdfFormFieldType.choice => Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    field.value.isEmpty ? field.name : field.value,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      color: field.value.isEmpty
                          ? Colors.blue.withValues(alpha: 0.6)
                          : Colors.black87,
                    ),
                  ),
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 16, color: Colors.blue),
            ],
          ),
        PdfFormFieldType.text => Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                field.value.isEmpty ? field.name : field.value,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11,
                  color: field.value.isEmpty
                      ? Colors.blue.withValues(alpha: 0.6)
                      : Colors.black87,
                ),
              ),
            ),
          ),
      },
    );
  }
}
