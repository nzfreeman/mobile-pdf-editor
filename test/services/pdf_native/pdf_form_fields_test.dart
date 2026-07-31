import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_form_fields.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_form_service.dart';

/// A minimal one-page PDF with an existing AcroForm: one text field
/// ("Name", empty value) and one checkbox ("Agree", unchecked, with
/// real /Off and /Yes appearance streams like a genuine form would have).
Uint8List _buildFormPdf() {
  final objects = <String, List<int>>{};
  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>\nendobj\n'.codeUnits;
  objects['2'] = '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'.codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] '
              '/Resources << >> /Contents 5 0 R /Annots [7 0 R 8 0 R] >>\nendobj\n'
          .codeUnits;

  const contentStream = 'q Q';
  final contentBytes = contentStream.codeUnits;
  objects['5'] = [
    ...'5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n'.codeUnits,
    ...contentBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];

  objects['6'] =
      '6 0 obj\n<< /Fields [7 0 R 8 0 R] /DA (/Helv 12 Tf 0 g) >>\nendobj\n'.codeUnits;

  // Text field: Rect in PDF space (y-up) 50..350 x, 500..530 y (top area
  // of a 600-tall page).
  objects['7'] =
      '7 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) '
              '/Rect [50 500 350 530] /V () /P 3 0 R >>\nendobj\n'
          .codeUnits;

  const offContent = '0 0 20 20 re S';
  const yesContent = '0 0 20 20 re S 2 2 m 18 18 l S';
  final offBytes = offContent.codeUnits;
  final yesBytes = yesContent.codeUnits;
  objects['9'] = [
    ...'9 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length ${offBytes.length} >>\nstream\n'
        .codeUnits,
    ...offBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];
  objects['10'] = [
    ...'10 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length ${yesBytes.length} >>\nstream\n'
        .codeUnits,
    ...yesBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];
  objects['8'] =
      '8 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) '
              '/Rect [50 450 70 470] /V /Off /AS /Off '
              '/AP << /N << /Yes 10 0 R /Off 9 0 R >> >> /P 3 0 R >>\nendobj\n'
          .codeUnits;

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  for (final key in ['1', '2', '3', '5', '6', '7', '8', '9', '10']) {
    offsets[int.parse(key)] = out.length;
    out.add(objects[key]!);
  }

  final xrefOffset = out.length;
  final xref = StringBuffer()
    ..writeln('xref')
    ..writeln('0 11')
    ..writeln('0000000000 65535 f ');
  for (var i = 1; i <= 10; i++) {
    final offset = offsets[i];
    xref.writeln(
      '${(offset ?? 0).toString().padLeft(10, '0')} 00000 ${offset == null ? 'f' : 'n'} ',
    );
  }
  xref
    ..writeln('trailer')
    ..writeln('<< /Size 11 /Root 1 0 R >>')
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
    final tempDir = await Directory.systemTemp.createTemp('form_test');
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

  test('extractFormFields finds the text field and checkbox with correct position/state', () {
    final doc = PdfDocument.parse(_buildFormPdf());
    final fields = extractFormFields(doc);
    expect(fields, hasLength(2));

    final nameField = fields.firstWhere((f) => f.name == 'Name');
    expect(nameField.type, PdfFormFieldType.text);
    expect(nameField.pageIndex, 0);
    expect(nameField.value, '');
    // Rect x 50..350 on a 400-wide page -> normX 0.125, normWidth 0.75.
    expect(nameField.normX, closeTo(0.125, 0.001));
    expect(nameField.normWidth, closeTo(0.75, 0.001));

    final agreeField = fields.firstWhere((f) => f.name == 'Agree');
    expect(agreeField.type, PdfFormFieldType.checkbox);
    expect(agreeField.checked, isFalse);
  });

  test('setTextFieldValue with ASCII text updates /V and re-parses correctly', () async {
    final tempDir = await Directory.systemTemp.createTemp('form_ascii_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/form.pdf');
    await file.writeAsBytes(_buildFormPdf());

    final fields = await PdfFormService.extractFields(file);
    final nameField = fields.firstWhere((f) => f.name == 'Name');

    final edited = await PdfFormService.setTextFieldValue(
      file: file,
      field: nameField,
      newValue: 'John Doe',
    );
    addTearDown(() => edited.delete());

    final doc = PdfDocument.parse(await edited.readAsBytes());
    final updatedFields = extractFormFields(doc);
    final updatedName = updatedFields.firstWhere((f) => f.name == 'Name');
    expect(updatedName.value, 'John Doe');
  });

  test('setTextFieldValue with Korean text embeds the fallback font and round-trips', () async {
    final tempDir = await Directory.systemTemp.createTemp('form_korean_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/form.pdf');
    await file.writeAsBytes(_buildFormPdf());

    final fields = await PdfFormService.extractFields(file);
    final nameField = fields.firstWhere((f) => f.name == 'Name');

    final edited = await PdfFormService.setTextFieldValue(
      file: file,
      field: nameField,
      newValue: '홍길동',
    );
    addTearDown(() => edited.delete());

    final doc = PdfDocument.parse(await edited.readAsBytes());
    final updatedFields = extractFormFields(doc);
    final updatedName = updatedFields.firstWhere((f) => f.name == 'Name');
    expect(updatedName.value, '홍길동');
  });

  test('toggleCheckbox flips /AS and /V without touching existing appearances', () async {
    final tempDir = await Directory.systemTemp.createTemp('form_checkbox_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/form.pdf');
    await file.writeAsBytes(_buildFormPdf());

    final fields = await PdfFormService.extractFields(file);
    final agreeField = fields.firstWhere((f) => f.name == 'Agree');
    expect(agreeField.checked, isFalse);

    final edited = await PdfFormService.toggleCheckbox(
      file: file,
      field: agreeField,
      checked: true,
    );
    addTearDown(() => edited.delete());

    final doc = PdfDocument.parse(await edited.readAsBytes());
    final updated = extractFormFields(doc).firstWhere((f) => f.name == 'Agree');
    expect(updated.checked, isTrue);
  });

  test('addTextField creates a new, independently discoverable field', () async {
    final tempDir = await Directory.systemTemp.createTemp('form_new_field_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/form.pdf');
    await file.writeAsBytes(_buildFormPdf());

    final edited = await PdfFormService.addTextField(
      file: file,
      pageIndex: 0,
      name: 'Email',
      normX: 0.1,
      normY: 0.3,
      normWidth: 0.5,
      normHeight: 0.05,
    );
    addTearDown(() => edited.delete());

    final doc = PdfDocument.parse(await edited.readAsBytes());
    final fields = extractFormFields(doc);
    expect(fields.map((f) => f.name), containsAll(['Name', 'Agree', 'Email']));
    final emailField = fields.firstWhere((f) => f.name == 'Email');
    expect(emailField.pageIndex, 0);
    expect(emailField.normX, closeTo(0.1, 0.001));
  });

  test('addCheckboxField creates a new checkbox that can then be toggled', () async {
    final tempDir = await Directory.systemTemp.createTemp('form_new_checkbox_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/form.pdf');
    await file.writeAsBytes(_buildFormPdf());

    final withNewCheckbox = await PdfFormService.addCheckboxField(
      file: file,
      pageIndex: 0,
      name: 'Subscribe',
      normX: 0.1,
      normY: 0.6,
      normWidth: 0.05,
      normHeight: 0.03,
    );
    addTearDown(() => withNewCheckbox.delete());

    final fields = await PdfFormService.extractFields(withNewCheckbox);
    final subscribeField = fields.firstWhere((f) => f.name == 'Subscribe');
    expect(subscribeField.checked, isFalse);

    final toggled = await PdfFormService.toggleCheckbox(
      file: withNewCheckbox,
      field: subscribeField,
      checked: true,
    );
    addTearDown(() => toggled.delete());

    final toggledFields = await PdfFormService.extractFields(toggled);
    expect(toggledFields.firstWhere((f) => f.name == 'Subscribe').checked, isTrue);
  });
}
