import 'dart:math' as math;
import 'dart:typed_data';

import 'pdf_document.dart';
import 'pdf_font.dart';
import 'pdf_lexer.dart';
import 'pdf_objects.dart';

/// A 2D affine transform, stored PDF-style as `[a b c d e f]`:
/// `x' = a*x + c*y + e`, `y' = b*x + d*y + f`.
class Mat2D {
  const Mat2D(this.a, this.b, this.c, this.d, this.e, this.f);
  static const identity = Mat2D(1, 0, 0, 1, 0, 0);

  final double a, b, c, d, e, f;

  /// Combines two transforms such that a point is transformed by `this`
  /// first, then by [other] — i.e. `this` is the "local" matrix being
  /// concatenated into an existing `other` (CTM or text) matrix.
  Mat2D multiply(Mat2D other) {
    return Mat2D(
      a * other.a + b * other.c,
      a * other.b + b * other.d,
      c * other.a + d * other.c,
      c * other.b + d * other.d,
      e * other.a + f * other.c + other.e,
      e * other.b + f * other.d + other.f,
    );
  }

  (double, double) apply(double x, double y) =>
      (a * x + c * y + e, b * x + d * y + f);

  /// Magnitude of the transform's y-basis vector — used as an approximate
  /// scale factor for font size, since we don't track full glyph-level
  /// typesetting (rotation/skew beyond simple scale is not reproduced).
  double get yScale => math.sqrt(c * c + d * d);

  /// Standard 2D affine inverse; returns null for a singular (non-
  /// invertible) matrix, which callers should treat as "skip this
  /// optimization" rather than crash.
  Mat2D? get inverse {
    final det = a * d - b * c;
    if (det == 0) return null;
    return Mat2D(
      d / det,
      -b / det,
      -c / det,
      a / det,
      (c * f - d * e) / det,
      (b * e - a * f) / det,
    );
  }
}

/// One text-showing operation (`Tj`/`TJ`/`'`/`"`) found while walking a
/// page's content stream, with enough context to redraw a covering
/// rectangle and re-insert replacement text at roughly the same place.
///
/// Position/size are approximate: this walker does not model text
/// rendering mode, character/word spacing, horizontal scaling, or rise,
/// which real PDF layout engines use for exact glyph placement. That
/// precision isn't needed to redact + re-show a short run of edited text.
class PdfTextRun {
  const PdfTextRun({
    required this.contentStreamRef,
    required this.byteStartInStream,
    required this.byteEndInStream,
    required this.fontResourceName,
    required this.fontRef,
    required this.font,
    required this.fontSize,
    required this.originX,
    required this.originY,
    required this.text,
    required this.ctm,
  });

  final PdfRef contentStreamRef;

  /// Byte offset range of the full operator (operands + keyword) within
  /// [contentStreamRef]'s own decoded bytes (not the page's concatenation
  /// of multiple content streams).
  final int byteStartInStream;
  final int byteEndInStream;

  final String fontResourceName;
  final PdfRef? fontRef;
  final PdfFontInfo font;
  final double fontSize;

  /// Text-origin point in page (PDF default user space, y-up) coordinates.
  final double originX;
  final double originY;

  final String text;

  /// The CTM active when this run was drawn — needed to neutralize it via
  /// its inverse when splicing in replacement operators, so the
  /// replacement lands at the same absolute page position regardless of
  /// whatever transform was active at that point in the stream.
  final Mat2D ctm;

  /// Whether this run's *own* text can round-trip through
  /// [PdfFontInfo.encode] — for CID fonts this is really "does this run
  /// have a ToUnicode map at all" (trivially true when it decoded to
  /// real text rather than placeholders), not a guarantee that arbitrary
  /// replacement text will also encode. Callers must still try encoding
  /// the actual replacement text and handle [PdfRunNotEditableException]
  /// — see pdf_native_edit_builder.dart.
  bool get isEditable => font.encode(text) != null;
}

class _GraphicsState {
  _GraphicsState(this.ctm);
  Mat2D ctm;
}

/// Walks the decoded content-stream bytes of [page] and returns every
/// text-showing operation found, translated back to byte ranges within
/// their original (per-object) content streams.
List<PdfTextRun> extractTextRuns(PdfDocument doc, PdfDictionaryObj page) {
  final content = doc.pageContent(page);
  final resources = doc.inheritedAttribute(page, 'Resources');
  final fontDictObj = resources is PdfDictionaryObj
      ? doc.resolve(resources['Font'])
      : null;
  final fontResources = fontDictObj is PdfDictionaryObj
      ? fontDictObj.entries
      : const <String, PdfObject>{};

  final fontCache = <String, PdfFontInfo>{};
  final fontRefCache = <String, PdfRef?>{};
  PdfFontInfo? fontFor(String name) {
    final cached = fontCache[name];
    if (cached != null) return cached;
    final ref = fontResources[name];
    if (ref is PdfRef) fontRefCache[name] = ref;
    final dict = doc.resolve(ref);
    if (dict is! PdfDictionaryObj) return null;
    final info = resolveFont(doc, dict);
    fontCache[name] = info;
    return info;
  }

  PdfRef? streamRefForOffset(int concatenatedOffset) {
    for (final segment in content.segments) {
      if (concatenatedOffset >= segment.$2 && concatenatedOffset < segment.$3) {
        return segment.$1;
      }
    }
    return null;
  }

  int toStreamLocalOffset(int concatenatedOffset, PdfRef streamRef) {
    for (final segment in content.segments) {
      if (segment.$1 == streamRef) return concatenatedOffset - segment.$2;
    }
    return concatenatedOffset;
  }

  final runs = <PdfTextRun>[];
  final lexer = PdfLexer(content.bytes, 0);
  final stack = <_GraphicsState>[_GraphicsState(Mat2D.identity)];
  var textMatrix = Mat2D.identity;
  var lineMatrix = Mat2D.identity;
  String? currentFontName;
  PdfFontInfo? currentFont;
  var currentFontSize = 0.0;

  final operands = <PdfObject>[];
  int? operatorStart;

  void resetOperands() {
    operands.clear();
    operatorStart = null;
  }

  double num_(PdfObject? obj) => obj is PdfNumber ? obj.doubleValue : 0;

  void advanceTextMatrix(String shownText) {
    final font = currentFont;
    if (font == null) return;
    final widthTextSpace =
        font.measureWidth(shownText) / font.unitsPerEm * currentFontSize;
    textMatrix = Mat2D(1, 0, 0, 1, widthTextSpace, 0).multiply(textMatrix);
  }

  void handleShow(String text, int opStart, int opEnd) {
    final font = currentFont;
    final fontName = currentFontName;
    if (font == null || fontName == null || text.isEmpty) {
      advanceTextMatrix(text);
      return;
    }
    final combined = textMatrix.multiply(stack.last.ctm);
    final (originX, originY) = combined.apply(0, 0);
    final streamRef = streamRefForOffset(opStart);
    if (streamRef != null) {
      runs.add(
        PdfTextRun(
          contentStreamRef: streamRef,
          byteStartInStream: toStreamLocalOffset(opStart, streamRef),
          byteEndInStream: toStreamLocalOffset(opEnd, streamRef),
          fontResourceName: fontName,
          fontRef: fontRefCache[fontName],
          font: font,
          fontSize: currentFontSize * combined.yScale,
          originX: originX,
          originY: originY,
          text: text,
          ctm: stack.last.ctm,
        ),
      );
    }
    advanceTextMatrix(text);
  }

  while (true) {
    final token = lexer.next();
    if (token.type == PdfTokenType.eof) break;
    operatorStart ??= token.start;

    switch (token.type) {
      case PdfTokenType.number:
        operands.add(PdfNumber(token.number!));
        continue;
      case PdfTokenType.name:
        operands.add(PdfName(token.text!));
        continue;
      case PdfTokenType.string:
        operands.add(PdfLiteralString(token.bytes!));
        continue;
      case PdfTokenType.arrayStart:
        final items = <PdfObject>[];
        while (true) {
          final peek = lexer.next();
          if (peek.type == PdfTokenType.arrayEnd ||
              peek.type == PdfTokenType.eof) {
            break;
          }
          if (peek.type == PdfTokenType.number) {
            items.add(PdfNumber(peek.number!));
          } else if (peek.type == PdfTokenType.string) {
            items.add(PdfLiteralString(peek.bytes!));
          } else if (peek.type == PdfTokenType.name) {
            items.add(PdfName(peek.text!));
          }
        }
        operands.add(PdfArrayObj(items));
        continue;
      case PdfTokenType.dictStart:
        // Inline image dicts (BI...ID...EI) or marked-content property
        // dicts aren't relevant to text extraction; skip to the matching
        // dictEnd shallowly.
        var depth = 1;
        while (depth > 0) {
          final t = lexer.next();
          if (t.type == PdfTokenType.eof) break;
          if (t.type == PdfTokenType.dictStart) depth++;
          if (t.type == PdfTokenType.dictEnd) depth--;
        }
        continue;
      case PdfTokenType.dictEnd:
      case PdfTokenType.arrayEnd:
        continue;
      case PdfTokenType.eof:
        break;
      case PdfTokenType.keyword:
        break;
    }

    final op = token.text;
    switch (op) {
      case 'q':
        stack.add(_GraphicsState(stack.last.ctm));
      case 'Q':
        if (stack.length > 1) stack.removeLast();
      case 'cm':
        if (operands.length >= 6) {
          final m = Mat2D(
            num_(operands[0]),
            num_(operands[1]),
            num_(operands[2]),
            num_(operands[3]),
            num_(operands[4]),
            num_(operands[5]),
          );
          stack.last.ctm = m.multiply(stack.last.ctm);
        }
      case 'BT':
        textMatrix = Mat2D.identity;
        lineMatrix = Mat2D.identity;
      case 'ET':
        break;
      case 'Tf':
        if (operands.length >= 2 && operands[0] is PdfName) {
          currentFontName = (operands[0] as PdfName).value;
          currentFontSize = num_(operands[1]);
          currentFont = fontFor(currentFontName);
        }
      case 'Tm':
        if (operands.length >= 6) {
          lineMatrix = Mat2D(
            num_(operands[0]),
            num_(operands[1]),
            num_(operands[2]),
            num_(operands[3]),
            num_(operands[4]),
            num_(operands[5]),
          );
          textMatrix = lineMatrix;
        }
      case 'Td':
        if (operands.length >= 2) {
          lineMatrix = Mat2D(
            1,
            0,
            0,
            1,
            num_(operands[0]),
            num_(operands[1]),
          ).multiply(lineMatrix);
          textMatrix = lineMatrix;
        }
      case 'TD':
        if (operands.length >= 2) {
          lineMatrix = Mat2D(
            1,
            0,
            0,
            1,
            num_(operands[0]),
            num_(operands[1]),
          ).multiply(lineMatrix);
          textMatrix = lineMatrix;
        }
      case 'T*':
        lineMatrix = const Mat2D(1, 0, 0, 1, 0, 0).multiply(lineMatrix);
        textMatrix = lineMatrix;
      case 'Tj':
        if (operands.isNotEmpty && operands.last is PdfLiteralString) {
          final font = currentFont;
          final bytes = (operands.last as PdfLiteralString).bytes;
          final text = font?.decode(bytes) ?? '';
          handleShow(text, operatorStart!, token.end);
        }
      case "'":
        lineMatrix = const Mat2D(1, 0, 0, 1, 0, 0).multiply(lineMatrix);
        textMatrix = lineMatrix;
        if (operands.isNotEmpty && operands.last is PdfLiteralString) {
          final font = currentFont;
          final bytes = (operands.last as PdfLiteralString).bytes;
          final text = font?.decode(bytes) ?? '';
          handleShow(text, operatorStart!, token.end);
        }
      case 'TJ':
        if (operands.isNotEmpty && operands.last is PdfArrayObj) {
          final font = currentFont;
          final array = (operands.last as PdfArrayObj).items;
          final buffer = StringBuffer();
          for (final item in array) {
            if (item is PdfLiteralString && font != null) {
              buffer.write(font.decode(item.bytes));
            }
          }
          handleShow(buffer.toString(), operatorStart!, token.end);
        }
      default:
        break;
    }
    resetOperands();
  }

  return runs;
}

Uint8List concatenatedBytesOf(PdfDocument doc, PdfDictionaryObj page) =>
    doc.pageContent(page).bytes;
