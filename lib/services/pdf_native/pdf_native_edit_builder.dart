import 'dart:typed_data';

import 'pdf_content_stream.dart';

class PdfRunNotEditableException implements Exception {
  PdfRunNotEditableException(this.message);
  final String message;

  @override
  String toString() => 'PdfRunNotEditableException: $message';
}

/// Builds the raw content-stream bytes that replace a [PdfTextRun]'s
/// original operator: a white rectangle covering the original glyphs,
/// followed by the new text drawn with the same font/resource at the same
/// origin. The whole thing is wrapped in `q ... cm ... Q` using the
/// inverse of the run's own CTM, so the coordinates below can be given
/// directly in absolute page space regardless of whatever transform was
/// active when the original text was drawn.
Uint8List buildReplacementOperatorBytes(PdfTextRun run, String newText) {
  final encoded = run.font.encode(newText);
  if (encoded == null) {
    throw PdfRunNotEditableException(
      'Font for this run cannot re-encode the replacement text '
      '(CID/Type0 fonts are read-only in this implementation)',
    );
  }
  final inverseCtm = run.ctm.inverse;
  if (inverseCtm == null) {
    throw PdfRunNotEditableException('Run has a non-invertible CTM');
  }

  final originalWidth =
      run.font.measureWidth(run.text) / run.font.unitsPerEm * run.fontSize;
  final descent = run.fontSize * 0.25;
  final ascent = run.fontSize * 0.9;
  final rectX = run.originX;
  final rectY = run.originY - descent;
  final rectWidth = originalWidth <= 0 ? run.fontSize : originalWidth;
  final rectHeight = descent + ascent;

  final buffer = StringBuffer()
    ..writeln('q')
    ..writeln(
      '${_fmt(inverseCtm.a)} ${_fmt(inverseCtm.b)} ${_fmt(inverseCtm.c)} '
      '${_fmt(inverseCtm.d)} ${_fmt(inverseCtm.e)} ${_fmt(inverseCtm.f)} cm',
    )
    ..writeln('1 1 1 rg')
    ..writeln(
      '${_fmt(rectX)} ${_fmt(rectY)} ${_fmt(rectWidth)} ${_fmt(rectHeight)} re f',
    )
    ..writeln('0 0 0 rg')
    ..writeln('BT')
    ..writeln('/${run.fontResourceName} ${_fmt(run.fontSize)} Tf')
    ..writeln('${_fmt(run.originX)} ${_fmt(run.originY)} Td');

  final head = buffer.toString();
  final out = BytesBuilder();
  out.add(head.codeUnits);
  out.addByte(0x28); // '('
  out.add(_escapeLiteral(encoded));
  out.addByte(0x29); // ')'
  out.add(' Tj\nET\nQ\n'.codeUnits);
  return out.toBytes();
}

String _fmt(double value) => value.toStringAsFixed(3);

Uint8List _escapeLiteral(Uint8List bytes) {
  final out = BytesBuilder();
  for (final b in bytes) {
    if (b == 0x28 || b == 0x29 || b == 0x5C) out.addByte(0x5C);
    out.addByte(b);
  }
  return out.toBytes();
}
