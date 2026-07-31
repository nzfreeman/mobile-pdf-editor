import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_form_fields.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_form_service.dart';

/// A one-page PDF with:
/// - a radio group ("Color": Red/Green, non-terminal parent field with
///   the Radio flag, two widget kids each with their own Yes/Off
///   appearances), initially "Red" selected
/// - a choice/combo field ("Size": Small/Medium/Large), initially empty
Uint8List _buildRadioChoicePdf() {
  final objects = <String, List<int>>{};
  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>\nendobj\n'.codeUnits;
  objects['2'] = '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'.codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] '
              '/Resources << >> /Contents 5 0 R /Annots [8 0 R 9 0 R 12 0 R] >>\nendobj\n'
          .codeUnits;

  const contentStream = 'q Q';
  final contentBytes = contentStream.codeUnits;
  objects['5'] = [
    ...'5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n'.codeUnits,
    ...contentBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];

  objects['6'] =
      '6 0 obj\n<< /Fields [7 0 R 12 0 R] /DA (/Helv 12 Tf 0 g) >>\nendobj\n'.codeUnits;

  // Radio group parent (non-terminal: no /Rect, has /Kids) with the
  // Radio flag (bit 15, value 1<<15 = 32768) set.
  objects['7'] =
      '7 0 obj\n<< /FT /Btn /T (Color) /Ff 32768 /V /Red /Kids [8 0 R 9 0 R] >>\nendobj\n'
          .codeUnits;

  const redOffContent = '0 0 15 15 re S';
  const redOnContent = '0 0 15 15 re S 3 3 9 9 re f';
  final redOffBytes = redOffContent.codeUnits;
  final redOnBytes = redOnContent.codeUnits;
  objects['10'] = [
    ...'10 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 15 15] /Length ${redOffBytes.length} >>\nstream\n'
        .codeUnits,
    ...redOffBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];
  objects['11'] = [
    ...'11 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 15 15] /Length ${redOnBytes.length} >>\nstream\n'
        .codeUnits,
    ...redOnBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];
  objects['8'] =
      '8 0 obj\n<< /Type /Annot /Subtype /Widget /Parent 7 0 R '
              '/Rect [50 500 65 515] /AS /Red /P 3 0 R '
              '/AP << /N << /Red 11 0 R /Off 10 0 R >> >> >>\nendobj\n'
          .codeUnits;
  objects['9'] =
      '9 0 obj\n<< /Type /Annot /Subtype /Widget /Parent 7 0 R '
              '/Rect [90 500 105 515] /AS /Off /P 3 0 R '
              '/AP << /N << /Green 11 0 R /Off 10 0 R >> >> >>\nendobj\n'
          .codeUnits;

  // Choice (combo box) field, merged field+widget.
  objects['12'] =
      '12 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Ch /T (Size) '
              '/Ff 131072 /Rect [50 400 200 425] /V () '
              '/Opt [(Small) (Medium) (Large)] /P 3 0 R >>\nendobj\n'
          .codeUnits;

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  for (final key in ['1', '2', '3', '5', '6', '7', '8', '9', '10', '11', '12']) {
    offsets[int.parse(key)] = out.length;
    out.add(objects[key]!);
  }

  final xrefOffset = out.length;
  final xref = StringBuffer()
    ..writeln('xref')
    ..writeln('0 13')
    ..writeln('0000000000 65535 f ');
  for (var i = 1; i <= 12; i++) {
    final offset = offsets[i];
    xref.writeln(
      '${(offset ?? 0).toString().padLeft(10, '0')} 00000 ${offset == null ? 'f' : 'n'} ',
    );
  }
  xref
    ..writeln('trailer')
    ..writeln('<< /Size 13 /Root 1 0 R >>')
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..write('%%EOF');
  out.add(xref.toString().codeUnits);

  return out.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('form_radio_choice_test');
    addTearDown(() => tempDir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return tempDir.path;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  test('extractFormFields expands a radio group into one field per widget option', () {
    final doc = PdfDocument.parse(_buildRadioChoicePdf());
    final fields = extractFormFields(doc);

    final radioOptions = fields.where((f) => f.type == PdfFormFieldType.radio).toList();
    expect(radioOptions, hasLength(2));
    expect(radioOptions.every((f) => f.name == 'Color'), isTrue);

    final redOption = radioOptions.firstWhere((f) => f.value == 'Red');
    final greenOption = radioOptions.firstWhere((f) => f.value == 'Green');
    expect(redOption.checked, isTrue);
    expect(greenOption.checked, isFalse);
  });

  test('extractFormFields reads a choice field with its options', () {
    final doc = PdfDocument.parse(_buildRadioChoicePdf());
    final fields = extractFormFields(doc);
    final sizeField = fields.firstWhere((f) => f.name == 'Size');
    expect(sizeField.type, PdfFormFieldType.choice);
    expect(sizeField.options, ['Small', 'Medium', 'Large']);
    expect(sizeField.value, '');
  });

  test('selectRadioOption updates the group /V and flips every sibling /AS', () async {
    final tempDir = await Directory.systemTemp.createTemp('radio_select_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/form.pdf');
    await file.writeAsBytes(_buildRadioChoicePdf());

    final fields = await PdfFormService.extractFields(file);
    final greenOption = fields.firstWhere(
      (f) => f.type == PdfFormFieldType.radio && f.value == 'Green',
    );

    final edited = await PdfFormService.selectRadioOption(
      file: file,
      selected: greenOption,
    );
    addTearDown(() => edited.delete());

    final updatedFields = await PdfFormService.extractFields(edited);
    final updatedRed = updatedFields.firstWhere(
      (f) => f.type == PdfFormFieldType.radio && f.value == 'Red',
    );
    final updatedGreen = updatedFields.firstWhere(
      (f) => f.type == PdfFormFieldType.radio && f.value == 'Green',
    );
    expect(updatedGreen.checked, isTrue);
    expect(updatedRed.checked, isFalse);
  });

  test('choice field value can be set via the existing text-field write path', () async {
    final tempDir = await Directory.systemTemp.createTemp('choice_select_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/form.pdf');
    await file.writeAsBytes(_buildRadioChoicePdf());

    final fields = await PdfFormService.extractFields(file);
    final sizeField = fields.firstWhere((f) => f.name == 'Size');

    final edited = await PdfFormService.setTextFieldValue(
      file: file,
      field: sizeField,
      newValue: 'Medium',
    );
    addTearDown(() => edited.delete());

    final updatedFields = await PdfFormService.extractFields(edited);
    final updatedSize = updatedFields.firstWhere((f) => f.name == 'Size');
    expect(updatedSize.value, 'Medium');
    expect(updatedSize.options, ['Small', 'Medium', 'Large']);
  });
}
