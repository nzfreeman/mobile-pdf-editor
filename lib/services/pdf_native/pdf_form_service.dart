import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'pdf_document.dart';
import 'pdf_font_embedder.dart';
import 'pdf_form_fields.dart';
import 'pdf_incremental_writer.dart';
import 'pdf_objects.dart';
import 'ttf_font_reader.dart';

/// Public entry point for reading and editing AcroForm fields — kept
/// separate from [PdfNativeTextService] since forms are a distinct
/// concern, but shares its fallback-font machinery (see
/// pdf_font_embedder.dart) for Korean/non-Latin1 field values.
class PdfFormService {
  PdfFormService._();

  static const _fallbackFontAsset = 'assets/fonts/NanumGothic-Regular.ttf';
  static TtfFontInfo? _cachedFallbackTtf;

  static Future<TtfFontInfo> _loadFallbackTtf() async {
    final cached = _cachedFallbackTtf;
    if (cached != null) return cached;
    final data = await rootBundle.load(_fallbackFontAsset);
    final ttf = parseTtf(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    _cachedFallbackTtf = ttf;
    return ttf;
  }

  static Future<List<PdfFormField>> extractFields(File file) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    return extractFormFields(doc);
  }

  static Future<File> setTextFieldValue({
    required File file,
    required PdfFormField field,
    required String newValue,
  }) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);

    final needsUnicode = newValue.codeUnits.any((c) => c > 0xFF);
    EmbeddedCidFont? fallback;
    final writes = <PdfObjectWrite>[];
    if (needsUnicode) {
      final ttf = await _loadFallbackTtf();
      final page = doc.pages[field.pageIndex];
      fallback = findExistingEmbeddedFont(doc, page, ttf);
      if (fallback == null) {
        final built = buildEmbeddedFontWrites(
          doc: doc,
          page: page,
          ttf: ttf,
          resourceName: _uniqueResourceName(doc, page),
        );
        fallback = built.font;
        writes.addAll(built.writes);
      }
    }

    writes.addAll(
      buildTextFieldValueWrites(
        doc: doc,
        field: field,
        newValue: newValue,
        fallbackFont: fallback,
      ),
    );

    return _writeAndSave(doc, bytes, writes);
  }

  static Future<File> toggleCheckbox({
    required File file,
    required PdfFormField field,
    required bool checked,
  }) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    final write = buildCheckboxToggleWrite(
      doc: doc,
      field: field,
      checked: checked,
    );
    return _writeAndSave(doc, bytes, [write]);
  }

  static Future<File> selectRadioOption({
    required File file,
    required PdfFormField selected,
  }) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    final writes = buildRadioSelectionWrites(doc: doc, selected: selected);
    return _writeAndSave(doc, bytes, writes);
  }

  static Future<File> addTextField({
    required File file,
    required int pageIndex,
    required String name,
    required double normX,
    required double normY,
    required double normWidth,
    required double normHeight,
  }) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    final page = doc.pages[pageIndex];

    final built = buildNewTextField(
      doc: doc,
      page: page,
      name: name,
      normX: normX,
      normY: normY,
      normWidth: normWidth,
      normHeight: normHeight,
    );
    final writes = [
      ...built.writes,
      buildPageAnnotWrite(doc: doc, page: page, fieldRef: built.fieldRef),
      buildAcroFormRegistrationWrite(doc: doc, fieldRef: built.fieldRef),
    ];
    return _writeAndSave(doc, bytes, writes);
  }

  static Future<File> addCheckboxField({
    required File file,
    required int pageIndex,
    required String name,
    required double normX,
    required double normY,
    required double normWidth,
    required double normHeight,
  }) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    final page = doc.pages[pageIndex];

    final built = buildNewCheckboxField(
      doc: doc,
      page: page,
      name: name,
      normX: normX,
      normY: normY,
      normWidth: normWidth,
      normHeight: normHeight,
    );
    final writes = [
      ...built.writes,
      buildPageAnnotWrite(doc: doc, page: page, fieldRef: built.fieldRef),
      buildAcroFormRegistrationWrite(doc: doc, fieldRef: built.fieldRef),
    ];
    return _writeAndSave(doc, bytes, writes);
  }

  static String _uniqueResourceName(PdfDocument doc, PdfDictionaryObj page) {
    final resources = doc.inheritedAttribute(page, 'Resources');
    final fontDict = resources is PdfDictionaryObj
        ? doc.resolve(resources['Font'])
        : null;
    final existing = fontDict is PdfDictionaryObj
        ? fontDict.entries.keys.toSet()
        : const <String>{};
    var i = 0;
    while (existing.contains('FBK$i')) {
      i++;
    }
    return 'FBK$i';
  }

  static Future<File> _writeAndSave(
    PdfDocument doc,
    Uint8List originalBytes,
    List<PdfObjectWrite> writes,
  ) async {
    final newBytes = applyObjectWrites(doc, originalBytes, writes);
    final directory = await getApplicationDocumentsDirectory();
    final output = File(
      '${directory.path}/form_edit_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(newBytes, flush: true);
    return output;
  }
}
