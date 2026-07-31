import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'pdf_document.dart';
import 'pdf_font_embedder.dart';
import 'pdf_incremental_writer.dart';
import 'pdf_objects.dart';

enum PdfFormFieldType { text, checkbox, radio, choice }

/// An AcroForm field, positioned in the same normalized (0-1, top-left
/// origin, y-down) coordinate system the rest of the app's editor
/// overlays use — converted from the PDF's own y-up `/Rect` + page
/// `/MediaBox` at parse time.
///
/// Scope, by design: text, checkbox, choice (combo/list) fields, and
/// radio button groups are all supported — covering the field types
/// that appear in the overwhelming majority of real-world forms.
/// Hierarchical *non-radio* field trees beyond one level (a field whose
/// kids are themselves non-terminal fields, rather than either radio
/// widgets or a single terminal field) are not walked — vanishingly rare
/// outside radio groups in practice.
class PdfFormField {
  const PdfFormField({
    required this.ref,
    required this.name,
    required this.type,
    required this.pageIndex,
    required this.normX,
    required this.normY,
    required this.normWidth,
    required this.normHeight,
    required this.rectPoints,
    required this.value,
    required this.checked,
    this.options = const [],
    this.radioGroupRef,
    this.radioSiblingRefs = const [],
  });

  final PdfRef ref;
  final String name;
  final PdfFormFieldType type;
  final int pageIndex;
  final double normX;
  final double normY;
  final double normWidth;
  final double normHeight;

  /// Raw `/Rect` width/height in PDF points (needed to size a
  /// regenerated appearance stream's own `/BBox`).
  final (double width, double height) rectPoints;

  /// Current value (text/choice), or this specific widget's on-state
  /// export name (radio/checkbox — for radio, compare against the
  /// group's `/V` to know whether *this* option is the selected one).
  final String value;
  final bool checked;

  /// Choice fields only: available option display strings.
  final List<String> options;

  /// Radio fields only: the parent (group) field object, which holds
  /// `/V`, and every sibling widget in the group (including this one) —
  /// selecting one option requires updating the group's `/V` plus every
  /// sibling's own `/AS`.
  final PdfRef? radioGroupRef;
  final List<PdfRef> radioSiblingRefs;
}

List<PdfFormField> extractFormFields(PdfDocument doc) {
  final root = doc.resolve(doc.trailer['Root']);
  if (root is! PdfDictionaryObj) return [];
  final acroForm = doc.resolve(root['AcroForm']);
  if (acroForm is! PdfDictionaryObj) return [];
  final fieldsArr = doc.resolve(acroForm['Fields']);
  if (fieldsArr is! PdfArrayObj) return [];

  final pages = doc.pages;
  final result = <PdfFormField>[];
  for (final item in fieldsArr.items) {
    if (item is! PdfRef) continue;
    final dict = doc.resolve(item);
    if (dict is! PdfDictionaryObj) continue;
    _walkField(doc, item, dict, pages, result);
  }
  return result;
}

void _walkField(
  PdfDocument doc,
  PdfRef ref,
  PdfDictionaryObj dict,
  List<PdfDictionaryObj> pages,
  List<PdfFormField> out,
) {
  final ft = (doc.resolve(dict['FT']) as PdfName?)?.value;
  final ff = (doc.resolve(dict['Ff']) as PdfNumber?)?.intValue ?? 0;
  const radioFlag = 1 << 15;
  final isRadioGroup = ft == 'Btn' && (ff & radioFlag) != 0;
  final kidsObj = doc.resolve(dict['Kids']);
  final hasOwnRect = dict['Rect'] != null;

  if (!hasOwnRect && kidsObj is PdfArrayObj) {
    if (isRadioGroup) {
      _parseRadioGroup(doc, ref, dict, kidsObj, pages, out);
    } else {
      // Non-terminal, non-radio node: descend into each kid field.
      for (final kidItem in kidsObj.items) {
        if (kidItem is! PdfRef) continue;
        final kidDict = doc.resolve(kidItem);
        if (kidDict is! PdfDictionaryObj) continue;
        _walkField(doc, kidItem, kidDict, pages, out);
      }
    }
    return;
  }

  if (ft == 'Ch') {
    final field = _parseChoiceField(doc, ref, dict, pages);
    if (field != null) out.add(field);
    return;
  }
  final field = _parseField(doc, ref, dict, pages);
  if (field != null) out.add(field);
}

({
  int pageIndex,
  double normX,
  double normY,
  double normWidth,
  double normHeight,
  (double, double) rectPoints,
})?
_resolveWidgetPosition(
  PdfDocument doc,
  PdfRef ref,
  PdfDictionaryObj dict,
  List<PdfDictionaryObj> pages,
) {
  final rectObj = doc.resolve(dict['Rect']);
  if (rectObj is! PdfArrayObj || rectObj.items.length < 4) return null;
  final rect = rectObj.items
      .map((o) => (doc.resolve(o) as PdfNumber?)?.doubleValue ?? 0.0)
      .toList();

  var pageIndex = -1;
  final pRef = dict['P'];
  if (pRef is PdfRef) {
    final pDict = doc.resolve(pRef);
    pageIndex = pages.indexWhere((p) => identical(p, pDict));
  }
  if (pageIndex < 0) {
    for (var i = 0; i < pages.length; i++) {
      final annots = doc.resolve(pages[i]['Annots']);
      if (annots is PdfArrayObj &&
          annots.items.any((a) => a is PdfRef && a == ref)) {
        pageIndex = i;
        break;
      }
    }
  }
  if (pageIndex < 0) return null;

  final page = pages[pageIndex];
  final mediaBoxObj = doc.inheritedAttribute(page, 'MediaBox');
  final mediaBox = _normalizeBox(
    mediaBoxObj is PdfArrayObj
        ? mediaBoxObj.items
              .map((o) => (doc.resolve(o) as PdfNumber?)?.doubleValue ?? 0.0)
              .toList()
        : [0.0, 0.0, 612.0, 792.0],
  );
  final pageWidth = mediaBox[2] - mediaBox[0];
  final pageHeight = mediaBox[3] - mediaBox[1];
  if (pageWidth <= 0 || pageHeight <= 0) return null;

  final normalizedRect = _normalizeBox(rect);
  final llx = normalizedRect[0], lly = normalizedRect[1];
  final urx = normalizedRect[2], ury = normalizedRect[3];
  return (
    pageIndex: pageIndex,
    normX: (llx - mediaBox[0]) / pageWidth,
    normY: (mediaBox[3] - ury) / pageHeight,
    normWidth: (urx - llx) / pageWidth,
    normHeight: (ury - lly) / pageHeight,
    rectPoints: (urx - llx, ury - lly),
  );
}

String _fieldName(PdfDocument doc, PdfDictionaryObj dict) {
  final ownT = doc.resolve(dict['T']);
  if (ownT is PdfLiteralString) return decodePdfTextString(ownT.bytes);
  final parent = doc.resolve(dict['Parent']);
  if (parent is PdfDictionaryObj) {
    final parentT = doc.resolve(parent['T']);
    if (parentT is PdfLiteralString) return decodePdfTextString(parentT.bytes);
  }
  return '';
}

PdfFormField? _parseField(
  PdfDocument doc,
  PdfRef ref,
  PdfDictionaryObj dict,
  List<PdfDictionaryObj> pages,
) {
  final position = _resolveWidgetPosition(doc, ref, dict, pages);
  if (position == null) return null;

  final ft = (doc.resolve(dict['FT']) as PdfName?)?.value;
  final type = ft == 'Btn' ? PdfFormFieldType.checkbox : PdfFormFieldType.text;
  final name = _fieldName(doc, dict);

  var value = '';
  var checked = false;
  if (type == PdfFormFieldType.text) {
    final vObj = doc.resolve(dict['V']);
    if (vObj is PdfLiteralString) value = decodePdfTextString(vObj.bytes);
  } else {
    final asObj = dict['AS'];
    checked = asObj is PdfName && asObj.value != 'Off';
  }

  return PdfFormField(
    ref: ref,
    name: name,
    type: type,
    pageIndex: position.pageIndex,
    normX: position.normX,
    normY: position.normY,
    normWidth: position.normWidth,
    normHeight: position.normHeight,
    rectPoints: position.rectPoints,
    value: value,
    checked: checked,
  );
}

PdfFormField? _parseChoiceField(
  PdfDocument doc,
  PdfRef ref,
  PdfDictionaryObj dict,
  List<PdfDictionaryObj> pages,
) {
  final position = _resolveWidgetPosition(doc, ref, dict, pages);
  if (position == null) return null;

  final options = <String>[];
  final optObj = doc.resolve(dict['Opt']);
  if (optObj is PdfArrayObj) {
    for (final opt in optObj.items) {
      final resolved = doc.resolve(opt);
      if (resolved is PdfLiteralString) {
        options.add(decodePdfTextString(resolved.bytes));
      } else if (resolved is PdfArrayObj && resolved.items.length >= 2) {
        final display = doc.resolve(resolved.items[1]);
        if (display is PdfLiteralString) {
          options.add(decodePdfTextString(display.bytes));
        }
      }
    }
  }

  final vObj = doc.resolve(dict['V']);
  final value = vObj is PdfLiteralString ? decodePdfTextString(vObj.bytes) : '';

  return PdfFormField(
    ref: ref,
    name: _fieldName(doc, dict),
    type: PdfFormFieldType.choice,
    pageIndex: position.pageIndex,
    normX: position.normX,
    normY: position.normY,
    normWidth: position.normWidth,
    normHeight: position.normHeight,
    rectPoints: position.rectPoints,
    value: value,
    checked: false,
    options: options,
  );
}

void _parseRadioGroup(
  PdfDocument doc,
  PdfRef groupRef,
  PdfDictionaryObj groupDict,
  PdfArrayObj kids,
  List<PdfDictionaryObj> pages,
  List<PdfFormField> out,
) {
  final name = _fieldName(doc, groupDict);
  final selectedObj = doc.resolve(groupDict['V']);
  final selectedName = selectedObj is PdfName ? selectedObj.value : null;

  final siblingRefs = <PdfRef>[
    for (final kidItem in kids.items)
      if (kidItem is PdfRef) kidItem,
  ];

  for (final kidRef in siblingRefs) {
    final kidDict = doc.resolve(kidRef);
    if (kidDict is! PdfDictionaryObj) continue;
    final position = _resolveWidgetPosition(doc, kidRef, kidDict, pages);
    if (position == null) continue;
    final onState = _onStateName(doc, kidDict);

    out.add(
      PdfFormField(
        ref: kidRef,
        name: name,
        type: PdfFormFieldType.radio,
        pageIndex: position.pageIndex,
        normX: position.normX,
        normY: position.normY,
        normWidth: position.normWidth,
        normHeight: position.normHeight,
        rectPoints: position.rectPoints,
        value: onState,
        checked: onState == selectedName,
        radioGroupRef: groupRef,
        radioSiblingRefs: siblingRefs,
      ),
    );
  }
}

/// `/Rect` and `/MediaBox` arrays are `[llx lly urx ury]` by convention,
/// but the PDF spec explicitly permits either corner to be given first
/// (readers "should" normalize them) — a handful of real-world producers
/// do write them backwards. Using such a box unnormalized would produce
/// negative widths/heights, which then propagate into things like an
/// appearance stream's `/BBox` (invalid PDF) or a negative-size overlay
/// rectangle in the UI, rather than failing safely.
List<double> _normalizeBox(List<double> box) {
  if (box.length < 4) return [0.0, 0.0, 612.0, 792.0];
  final x0 = box[0] < box[2] ? box[0] : box[2];
  final x1 = box[0] < box[2] ? box[2] : box[0];
  final y0 = box[1] < box[3] ? box[1] : box[3];
  final y1 = box[1] < box[3] ? box[3] : box[1];
  return [x0, y0, x1, y1];
}

String decodePdfTextString(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final codeUnits = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(codeUnits);
  }
  return latin1.decode(bytes, allowInvalid: true);
}

Uint8List encodePdfTextString(String text) {
  final needsUnicode = text.codeUnits.any((c) => c > 0xFF);
  if (!needsUnicode) return Uint8List.fromList(latin1.encode(text));
  final out = BytesBuilder()
    ..addByte(0xFE)
    ..addByte(0xFF);
  for (final unit in text.codeUnits) {
    out.addByte((unit >> 8) & 0xFF);
    out.addByte(unit & 0xFF);
  }
  return out.toBytes();
}

Uint8List _escapeLiteral(Uint8List bytes) {
  final out = BytesBuilder();
  for (final b in bytes) {
    if (b == 0x28 || b == 0x29 || b == 0x5C) out.addByte(0x5C);
    out.addByte(b);
  }
  return out.toBytes();
}

/// Builds the writes needed to set a text field's value: the field
/// dict's own `/V` plus a freshly regenerated `/AP /N` appearance stream
/// (so the value actually renders, rather than relying on
/// `/NeedAppearances`, which many simple viewers don't honor).
///
/// Pure-ASCII/Latin-1 values use the standard (unembedded) Helvetica
/// font — no PDF changes needed beyond the field/appearance objects.
/// Anything else (Korean, etc.) needs a real embedded font; [fallbackFont]
/// must be provided in that case (see pdf_font_embedder.dart — same
/// bundled font already used for native text edits).
List<PdfObjectWrite> buildTextFieldValueWrites({
  required PdfDocument doc,
  required PdfFormField field,
  required String newValue,
  EmbeddedCidFont? fallbackFont,
}) {
  final dict = doc.getObject(field.ref);
  if (dict is! PdfDictionaryObj) {
    throw PdfNativeEditException('Field object is not a dictionary');
  }

  final apObjNum = doc.allocateNewObjectNumbers(1);
  final apRef = PdfRef(apObjNum, 0);

  final (width, height) = field.rectPoints;
  final fontSize = math.min(14.0, height * 0.65).clamp(6.0, 14.0);
  final needsUnicode = newValue.codeUnits.any((c) => c > 0xFF);

  String resourcesDict;
  Uint8List textOperandBytes;
  bool isHex;
  if (!needsUnicode || fallbackFont == null) {
    resourcesDict =
        '<< /Font << /Helv << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>';
    textOperandBytes = Uint8List.fromList(latin1.encode(newValue));
    isHex = false;
  } else {
    final encoded = fallbackFont.encode(newValue);
    if (encoded == null) {
      throw PdfNativeEditException(
        'Fallback font cannot represent this value',
      );
    }
    resourcesDict =
        '<< /Font << /Helv ${fallbackFont.fontRef.objectNumber} ${fallbackFont.fontRef.generation} R >> >>';
    textOperandBytes = encoded;
    isHex = true;
  }

  final textOperand = isHex
      ? '<${textOperandBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}>'
      : '(${latin1.decode(_escapeLiteral(textOperandBytes), allowInvalid: true)})';

  final content =
      '/Tx BMC\nq\nBT\n/Helv ${fontSize.toStringAsFixed(2)} Tf\n0 g\n'
      '2 ${((height - fontSize) / 2).toStringAsFixed(2)} Td\n'
      '$textOperand Tj\nET\nQ\nEMC';
  final contentBytes = Uint8List.fromList(content.codeUnits);

  final apDict = <String, PdfObject>{
    'Type': const PdfName('XObject'),
    'Subtype': const PdfName('Form'),
    'FormType': const PdfNumber(1),
    'BBox': PdfArrayObj([
      const PdfNumber(0),
      const PdfNumber(0),
      PdfNumber(width),
      PdfNumber(height),
    ]),
    'Length': PdfNumber(contentBytes.length),
  };
  final apBody = BytesBuilder()
    ..add(encodeDict(apDict).codeUnits)
    ..add('\n/Resources $resourcesDict\nstream\n'.codeUnits)
    ..add(contentBytes)
    ..add('\nendstream'.codeUnits);

  final newFieldEntries = Map<String, PdfObject>.from(dict.entries)
    ..['V'] = PdfLiteralString(encodePdfTextString(newValue))
    ..['AP'] = PdfDictionaryObj({'N': apRef})
    ..putIfAbsent(
      'DA',
      () => PdfLiteralString(Uint8List.fromList(latin1.encode('/Helv 12 Tf 0 g'))),
    );

  return [
    PdfObjectWrite(
      objectNumber: apRef.objectNumber,
      generation: 0,
      body: apBody.toBytes(),
    ),
    PdfObjectWrite(
      objectNumber: field.ref.objectNumber,
      generation: field.ref.generation,
      body: Uint8List.fromList(encodeDict(newFieldEntries).codeUnits),
    ),
  ];
}

/// Toggles an existing checkbox field's checked state. Reuses whatever
/// `/AP /N` appearance sub-dictionary the form already defines (real
/// forms almost always ship both an on-state and `/Off` appearance
/// already) rather than guessing at a checkmark glyph — only `/AS`
/// (and `/V`) change.
PdfObjectWrite buildCheckboxToggleWrite({
  required PdfDocument doc,
  required PdfFormField field,
  required bool checked,
}) {
  final dict = doc.getObject(field.ref);
  if (dict is! PdfDictionaryObj) {
    throw PdfNativeEditException('Field object is not a dictionary');
  }
  final onState = _onStateName(doc, dict);
  final stateName = checked ? onState : 'Off';

  final newEntries = Map<String, PdfObject>.from(dict.entries)
    ..['V'] = PdfName(stateName)
    ..['AS'] = PdfName(stateName);

  return PdfObjectWrite(
    objectNumber: field.ref.objectNumber,
    generation: field.ref.generation,
    body: Uint8List.fromList(encodeDict(newEntries).codeUnits),
  );
}

/// Selects one option within a radio button group: sets the group
/// field's `/V` to the chosen widget's on-state name, and flips every
/// sibling widget's own `/AS` (selected -> its on-state, everyone else
/// -> `/Off`) — a radio group's "checked" state genuinely lives across
/// multiple objects, unlike a standalone checkbox.
List<PdfObjectWrite> buildRadioSelectionWrites({
  required PdfDocument doc,
  required PdfFormField selected,
}) {
  final groupRef = selected.radioGroupRef;
  if (groupRef == null || selected.radioSiblingRefs.isEmpty) {
    throw PdfNativeEditException('Field is not part of a radio group');
  }
  final groupDict = doc.getObject(groupRef);
  if (groupDict is! PdfDictionaryObj) {
    throw PdfNativeEditException('Radio group object is not a dictionary');
  }

  final newGroupEntries = Map<String, PdfObject>.from(groupDict.entries)
    ..['V'] = PdfName(selected.value);
  final writes = <PdfObjectWrite>[
    PdfObjectWrite(
      objectNumber: groupRef.objectNumber,
      generation: groupRef.generation,
      body: Uint8List.fromList(encodeDict(newGroupEntries).codeUnits),
    ),
  ];

  for (final siblingRef in selected.radioSiblingRefs) {
    final siblingDict = doc.getObject(siblingRef);
    if (siblingDict is! PdfDictionaryObj) continue;
    final onState = _onStateName(doc, siblingDict);
    final isSelected = siblingRef == selected.ref;
    final newEntries = Map<String, PdfObject>.from(siblingDict.entries)
      ..['AS'] = PdfName(isSelected ? onState : 'Off');
    writes.add(
      PdfObjectWrite(
        objectNumber: siblingRef.objectNumber,
        generation: siblingRef.generation,
        body: Uint8List.fromList(encodeDict(newEntries).codeUnits),
      ),
    );
  }
  return writes;
}

String _onStateName(PdfDocument doc, PdfDictionaryObj dict) {
  final ap = doc.resolve(dict['AP']);
  if (ap is PdfDictionaryObj) {
    final n = doc.resolve(ap['N']);
    if (n is PdfDictionaryObj) {
      for (final key in n.entries.keys) {
        if (key != 'Off') return key;
      }
    }
  }
  return 'Yes';
}

/// Builds a brand-new checkbox field (both `/Yes` and `/Off` appearance
/// states drawn as plain vector paths — no font needed at all) plus the
/// writes to register it on [page] and in the document's `/AcroForm`.
({PdfRef fieldRef, List<PdfObjectWrite> writes}) buildNewCheckboxField({
  required PdfDocument doc,
  required PdfDictionaryObj page,
  required String name,
  required double normX,
  required double normY,
  required double normWidth,
  required double normHeight,
}) {
  final mediaBoxObj = doc.inheritedAttribute(page, 'MediaBox');
  final mediaBox = _normalizeBox(
    mediaBoxObj is PdfArrayObj
        ? mediaBoxObj.items
              .map((o) => (doc.resolve(o) as PdfNumber?)?.doubleValue ?? 0.0)
              .toList()
        : [0.0, 0.0, 612.0, 792.0],
  );
  final pageWidth = mediaBox[2] - mediaBox[0];
  final pageHeight = mediaBox[3] - mediaBox[1];

  final llx = mediaBox[0] + normX * pageWidth;
  final ury = mediaBox[3] - normY * pageHeight;
  final width = normWidth * pageWidth;
  final height = normHeight * pageHeight;
  final urx = llx + width;
  final lly = ury - height;

  final startObjNum = doc.allocateNewObjectNumbers(3);
  final offApRef = PdfRef(startObjNum, 0);
  final onApRef = PdfRef(startObjNum + 1, 0);
  final fieldRef = PdfRef(startObjNum + 2, 0);

  final offContent = '${_boxOutline(width, height)} S';
  final onContent =
      '${_boxOutline(width, height)} S\n${_checkmarkPath(width, height)} S';

  PdfObjectWrite buildAppearance(PdfRef ref, String content) {
    final bytes = Uint8List.fromList(content.codeUnits);
    final dict = <String, PdfObject>{
      'Type': const PdfName('XObject'),
      'Subtype': const PdfName('Form'),
      'FormType': const PdfNumber(1),
      'BBox': PdfArrayObj([
        const PdfNumber(0),
        const PdfNumber(0),
        PdfNumber(width),
        PdfNumber(height),
      ]),
      'Length': PdfNumber(bytes.length),
    };
    final body = BytesBuilder()
      ..add(encodeDict(dict).codeUnits)
      ..add('\nstream\n'.codeUnits)
      ..add(bytes)
      ..add('\nendstream'.codeUnits);
    return PdfObjectWrite(
      objectNumber: ref.objectNumber,
      generation: 0,
      body: body.toBytes(),
    );
  }

  final fieldDict = <String, PdfObject>{
    'Type': const PdfName('Annot'),
    'Subtype': const PdfName('Widget'),
    'FT': const PdfName('Btn'),
    'T': PdfLiteralString(encodePdfTextString(name)),
    'Rect': PdfArrayObj([
      PdfNumber(llx),
      PdfNumber(lly),
      PdfNumber(urx),
      PdfNumber(ury),
    ]),
    'F': const PdfNumber(4), // Print flag
    'V': const PdfName('Off'),
    'AS': const PdfName('Off'),
    'AP': PdfDictionaryObj({
      'N': PdfDictionaryObj({'Yes': onApRef, 'Off': offApRef}),
    }),
  };

  final writes = [
    buildAppearance(offApRef, offContent),
    buildAppearance(onApRef, onContent),
    PdfObjectWrite(
      objectNumber: fieldRef.objectNumber,
      generation: 0,
      body: Uint8List.fromList(encodeDict(fieldDict).codeUnits),
    ),
  ];

  return (fieldRef: fieldRef, writes: writes);
}

String _boxOutline(double width, double height) {
  const margin = 1.5;
  return '${margin.toStringAsFixed(2)} ${margin.toStringAsFixed(2)} '
      '${(width - margin * 2).toStringAsFixed(2)} ${(height - margin * 2).toStringAsFixed(2)} re';
}

String _checkmarkPath(double width, double height) {
  final x0 = width * 0.2, y0 = height * 0.5;
  final x1 = width * 0.4, y1 = height * 0.25;
  final x2 = width * 0.8, y2 = height * 0.75;
  return '${x0.toStringAsFixed(2)} ${y0.toStringAsFixed(2)} m '
      '${x1.toStringAsFixed(2)} ${y1.toStringAsFixed(2)} l '
      '${x2.toStringAsFixed(2)} ${y2.toStringAsFixed(2)} l';
}

/// Builds a brand-new empty text field plus the writes to register it on
/// [page] and in the document's `/AcroForm`. Call
/// [buildTextFieldValueWrites] afterward (in the same batch, or a later
/// edit) to actually give it a value/appearance.
({PdfRef fieldRef, List<PdfObjectWrite> writes}) buildNewTextField({
  required PdfDocument doc,
  required PdfDictionaryObj page,
  required String name,
  required double normX,
  required double normY,
  required double normWidth,
  required double normHeight,
}) {
  final mediaBoxObj = doc.inheritedAttribute(page, 'MediaBox');
  final mediaBox = _normalizeBox(
    mediaBoxObj is PdfArrayObj
        ? mediaBoxObj.items
              .map((o) => (doc.resolve(o) as PdfNumber?)?.doubleValue ?? 0.0)
              .toList()
        : [0.0, 0.0, 612.0, 792.0],
  );
  final pageWidth = mediaBox[2] - mediaBox[0];
  final pageHeight = mediaBox[3] - mediaBox[1];

  final llx = mediaBox[0] + normX * pageWidth;
  final ury = mediaBox[3] - normY * pageHeight;
  final urx = llx + normWidth * pageWidth;
  final lly = ury - normHeight * pageHeight;

  final fieldRef = PdfRef(doc.allocateNewObjectNumbers(1), 0);
  final fieldDict = <String, PdfObject>{
    'Type': const PdfName('Annot'),
    'Subtype': const PdfName('Widget'),
    'FT': const PdfName('Tx'),
    'T': PdfLiteralString(encodePdfTextString(name)),
    'Rect': PdfArrayObj([
      PdfNumber(llx),
      PdfNumber(lly),
      PdfNumber(urx),
      PdfNumber(ury),
    ]),
    'F': const PdfNumber(4),
    'V': PdfLiteralString(Uint8List(0)),
    'DA': PdfLiteralString(Uint8List.fromList(latin1.encode('/Helv 12 Tf 0 g'))),
  };

  return (
    fieldRef: fieldRef,
    writes: [
      PdfObjectWrite(
        objectNumber: fieldRef.objectNumber,
        generation: 0,
        body: Uint8List.fromList(encodeDict(fieldDict).codeUnits),
      ),
    ],
  );
}

/// Registers [fieldRef] on [page]'s `/Annots` array — required for any
/// newly created field to actually be visible/interactive.
PdfObjectWrite buildPageAnnotWrite({
  required PdfDocument doc,
  required PdfDictionaryObj page,
  required PdfRef fieldRef,
}) {
  final pageRef = doc.refOf(page);
  if (pageRef == null) {
    throw PdfNativeEditException("Couldn't determine the page's own object reference");
  }
  final existing = doc.resolve(page['Annots']);
  final annotRefs = <PdfObject>[
    if (existing is PdfArrayObj) ...existing.items,
    fieldRef,
  ];
  final newEntries = Map<String, PdfObject>.from(page.entries)
    ..['Annots'] = PdfArrayObj(annotRefs);
  return PdfObjectWrite(
    objectNumber: pageRef.objectNumber,
    generation: pageRef.generation,
    body: Uint8List.fromList(encodeDict(newEntries).codeUnits),
  );
}

/// Registers [fieldRef] in the document catalog's `/AcroForm /Fields`
/// array, creating `/AcroForm` if the document didn't have one yet.
PdfObjectWrite buildAcroFormRegistrationWrite({
  required PdfDocument doc,
  required PdfRef fieldRef,
}) {
  final root = doc.resolve(doc.trailer['Root']);
  if (root is! PdfDictionaryObj) {
    throw PdfNativeEditException('Document has no valid /Root catalog');
  }
  final rootRef = doc.refOf(root);
  if (rootRef == null) {
    throw PdfNativeEditException("Couldn't determine the catalog's own object reference");
  }

  final existingAcroForm = doc.resolve(root['AcroForm']);
  final acroFormEntries = Map<String, PdfObject>.from(
    existingAcroForm is PdfDictionaryObj ? existingAcroForm.entries : {},
  );
  final existingFields = doc.resolve(acroFormEntries['Fields']);
  final fieldRefs = <PdfObject>[
    if (existingFields is PdfArrayObj) ...existingFields.items,
    fieldRef,
  ];
  acroFormEntries['Fields'] = PdfArrayObj(fieldRefs);
  acroFormEntries.putIfAbsent(
    'DA',
    () => PdfLiteralString(Uint8List.fromList(latin1.encode('/Helv 12 Tf 0 g'))),
  );
  acroFormEntries['NeedAppearances'] = const PdfBool(false);

  final newRootEntries = Map<String, PdfObject>.from(root.entries)
    ..['AcroForm'] = PdfDictionaryObj(acroFormEntries);
  return PdfObjectWrite(
    objectNumber: rootRef.objectNumber,
    generation: rootRef.generation,
    body: Uint8List.fromList(encodeDict(newRootEntries).codeUnits),
  );
}
