import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/models/editor_item.dart';

void main() {
  test('copy creates independent mutable fields', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final item = EditorItem(
      id: 'item-1',
      type: EditorItemType.image,
      pageIndex: 0,
      x: 0.1,
      y: 0.2,
      bytes: bytes,
      points: const [DrawingPoint(0.1, 0.2)],
    );

    final copied = item.copy();
    item.bytes![0] = 9;
    item.points = const [DrawingPoint(0.8, 0.9)];

    expect(copied.bytes, orderedEquals([1, 2, 3]));
    expect(copied.points.single.dx, 0.1);
    expect(copied.points.single.dy, 0.2);
  });
}
