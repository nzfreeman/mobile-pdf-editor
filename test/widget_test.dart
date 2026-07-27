import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_service.dart';

void main() {
  test('rendered PDF page exposes aspect ratio', () {
    final page = RenderedPdfPage(
      bytes: Uint8List.fromList([1, 2, 3]),
      width: 200,
      height: 100,
    );

    expect(page.aspectRatio, 2);
  });
}
