import 'dart:math' as math;
import 'dart:typed_data';

import 'pdf_content_stream.dart';
import 'pdf_font_embedder.dart';

class PdfRunNotEditableException implements Exception {
  PdfRunNotEditableException(this.message);
  final String message;

  @override
  String toString() => 'PdfRunNotEditableException: $message';
}

/// Builds the raw content-stream bytes that replace a [PdfTextRun]'s
/// original operator: a white rectangle covering the original glyphs,
/// followed by the new text drawn at the same origin/size, word-wrapped
/// across as many lines as needed rather than running off the page when
/// the replacement is longer than the original. The whole thing is
/// wrapped in `q ... cm ... Q` using the inverse of the run's own CTM,
/// so the coordinates below can be given directly in absolute page space
/// regardless of whatever transform was active when the original text
/// was drawn.
///
/// Font selection: the run's own font resource is used whenever it can
/// represent [newText] (see [PdfFontInfo.encode]). When it can't —
/// [fallbackFont] is supplied and *it* can represent the text — the
/// fallback font resource is used to draw the whole replacement instead,
/// which is simpler and more predictable than trying to mix fonts
/// mid-run for a handful of unrepresentable characters.
Uint8List buildReplacementOperatorBytes(
  PdfTextRun run,
  String newText, {
  EmbeddedCidFont? fallbackFont,
}) {
  double Function(String) widthOf = run.font.widthOf;
  double unitsPerEm = run.font.unitsPerEm;
  var fontResourceName = run.fontResourceName;
  var usesFallback = false;

  // Newlines are handled as explicit line breaks by _wrapLines below and
  // never actually reach a font's encode() call; probe with them
  // stripped so this capability check doesn't spuriously fail just
  // because '\n' itself isn't a representable glyph.
  final probeText = newText.replaceAll('\n', ' ');
  var encodeLine = run.font.encode;
  if (encodeLine(probeText) == null) {
    final fb = fallbackFont;
    if (fb == null || fb.encode(probeText) == null) {
      throw PdfRunNotEditableException(
        'Neither the original font nor the fallback font can represent '
        'the replacement text',
      );
    }
    encodeLine = fb.encode;
    widthOf = fb.widthOf;
    unitsPerEm = 1000; // EmbeddedCidFont.widthOf already normalizes to this.
    fontResourceName = fb.resourceName;
    usesFallback = true;
  }

  final inverseCtm = run.ctm.inverse;
  if (inverseCtm == null) {
    throw PdfRunNotEditableException('Run has a non-invertible CTM');
  }

  final originalWidth =
      run.font.measureWidth(run.text) / run.font.unitsPerEm * run.fontSize;
  // Wrap to roughly the same footprint the original text occupied so a
  // longer replacement doesn't run off the page — but never so narrow
  // that even short replacements wrap absurdly (a field that originally
  // held a single short code, say).
  final wrapWidth = math.max(originalWidth, run.fontSize * 15);

  double measureLine(String line) {
    var total = 0.0;
    for (final rune in line.runes) {
      total += widthOf(String.fromCharCode(rune));
    }
    return total / unitsPerEm * run.fontSize;
  }

  final lines = _wrapLines(newText, wrapWidth, measureLine);
  final encodedLines = <Uint8List>[];
  for (final line in lines) {
    final encoded = encodeLine(line);
    if (encoded == null) {
      // Only possible if usesFallback is also false and some other
      // per-line quirk trips the original font's encoder — treat as
      // globally unsupported rather than partially render.
      throw PdfRunNotEditableException(
        usesFallback
            ? 'Fallback font cannot represent this text'
            : 'Font cannot represent this text',
      );
    }
    encodedLines.add(encoded);
  }

  final descent = run.fontSize * 0.25;
  final ascent = run.fontSize * 0.9;
  final lineHeight = run.fontSize * 1.15;
  final lineWidths = lines.map(measureLine).toList();
  final maxLineWidth = lineWidths.isEmpty
      ? wrapWidth
      : lineWidths.reduce(math.max);

  final rectX = run.originX;
  final rectY = run.originY - descent - lineHeight * (lines.length - 1);
  final rectWidth = maxLineWidth <= 0 ? run.fontSize : maxLineWidth;
  final rectHeight = descent + ascent + lineHeight * (lines.length - 1);

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
    ..writeln('/$fontResourceName ${_fmt(run.fontSize)} Tf')
    ..writeln('${_fmt(run.originX)} ${_fmt(run.originY)} Td');

  final out = BytesBuilder();
  out.add(buffer.toString().codeUnits);
  for (var i = 0; i < encodedLines.length; i++) {
    if (i > 0) out.add('0 ${_fmt(-lineHeight)} Td\n'.codeUnits);
    out.addByte(0x28); // '('
    out.add(_escapeLiteral(encodedLines[i]));
    out.addByte(0x29); // ')'
    out.add(' Tj\n'.codeUnits);
  }
  out.add('ET\nQ\n'.codeUnits);
  return out.toBytes();
}

/// Greedily wraps [text] on whitespace so each line's measured width
/// (via [measureLine]) stays within [maxWidth] where possible. A single
/// word wider than [maxWidth] on its own is still placed alone on a
/// line rather than split mid-word — a small remaining overflow is far
/// less disruptive than character-level hyphenation logic would be
/// worth here.
List<String> _wrapLines(
  String text,
  double maxWidth,
  double Function(String) measureLine,
) {
  final paragraphs = text.split('\n');
  final lines = <String>[];
  for (final paragraph in paragraphs) {
    final words = paragraph.split(' ');
    var current = '';
    for (final word in words) {
      final candidate = current.isEmpty ? word : '$current $word';
      if (current.isEmpty || measureLine(candidate) <= maxWidth) {
        current = candidate;
      } else {
        lines.add(current);
        current = word;
      }
    }
    lines.add(current);
  }
  return lines.isEmpty ? [''] : lines;
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
