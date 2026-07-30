import 'dart:typed_data';

enum PdfTokenType {
  number,
  name,
  string,
  arrayStart,
  arrayEnd,
  dictStart,
  dictEnd,
  keyword,
  eof,
}

class PdfToken {
  const PdfToken(this.type, {this.number, this.text, this.bytes, required this.start, required this.end});

  final PdfTokenType type;
  final num? number;
  final String? text;
  final Uint8List? bytes;

  /// Byte offsets of this token within the source, used by callers that
  /// need to splice/replace specific operators later.
  final int start;
  final int end;
}

bool _isWhitespace(int b) =>
    b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32;

bool _isDelimiter(int b) =>
    b == 0x28 || // (
    b == 0x29 || // )
    b == 0x3C || // <
    b == 0x3E || // >
    b == 0x5B || // [
    b == 0x5D || // ]
    b == 0x7B || // {
    b == 0x7D || // }
    b == 0x2F || // /
    b == 0x25; // %

/// Tokenizes both PDF object syntax and content-stream syntax — the
/// grammars are the same at the lexical level; only the higher-level
/// parsers interpreting the token stream differ.
class PdfLexer {
  PdfLexer(this.bytes, [this.pos = 0]);

  final Uint8List bytes;
  int pos;

  int get length => bytes.length;

  void skipWhitespaceAndComments() {
    while (pos < length) {
      final b = bytes[pos];
      if (_isWhitespace(b)) {
        pos++;
      } else if (b == 0x25) {
        // % comment to end of line
        while (pos < length && bytes[pos] != 10 && bytes[pos] != 13) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  PdfToken next() {
    skipWhitespaceAndComments();
    final start = pos;
    if (pos >= length) {
      return PdfToken(PdfTokenType.eof, start: start, end: pos);
    }
    final b = bytes[pos];

    if (b == 0x2F) return _readName();
    if (b == 0x28) return _readLiteralString();
    if (b == 0x3C) {
      if (pos + 1 < length && bytes[pos + 1] == 0x3C) {
        pos += 2;
        return PdfToken(PdfTokenType.dictStart, start: start, end: pos);
      }
      return _readHexString();
    }
    if (b == 0x3E) {
      if (pos + 1 < length && bytes[pos + 1] == 0x3E) {
        pos += 2;
        return PdfToken(PdfTokenType.dictEnd, start: start, end: pos);
      }
      pos++;
      return PdfToken(PdfTokenType.dictEnd, start: start, end: pos);
    }
    if (b == 0x5B) {
      pos++;
      return PdfToken(PdfTokenType.arrayStart, start: start, end: pos);
    }
    if (b == 0x5D) {
      pos++;
      return PdfToken(PdfTokenType.arrayEnd, start: start, end: pos);
    }
    if (b == 0x2B || b == 0x2D || b == 0x2E || (b >= 0x30 && b <= 0x39)) {
      return _readNumberOrKeyword();
    }
    return _readKeyword();
  }

  PdfToken _readName() {
    final start = pos;
    pos++; // skip '/'
    final buffer = BytesBuilder();
    while (pos < length && !_isWhitespace(bytes[pos]) && !_isDelimiter(bytes[pos])) {
      if (bytes[pos] == 0x23 && pos + 2 < length) {
        final hex = String.fromCharCodes(bytes.sublist(pos + 1, pos + 3));
        final code = int.tryParse(hex, radix: 16);
        if (code != null) {
          buffer.addByte(code);
          pos += 3;
          continue;
        }
      }
      buffer.addByte(bytes[pos]);
      pos++;
    }
    return PdfToken(
      PdfTokenType.name,
      text: String.fromCharCodes(buffer.toBytes()),
      start: start,
      end: pos,
    );
  }

  PdfToken _readLiteralString() {
    final start = pos;
    pos++; // skip '('
    final buffer = BytesBuilder();
    var depth = 1;
    while (pos < length && depth > 0) {
      final b = bytes[pos];
      if (b == 0x5C) {
        pos++;
        if (pos >= length) break;
        final esc = bytes[pos];
        switch (esc) {
          case 0x6E:
            buffer.addByte(10);
            pos++;
          case 0x72:
            buffer.addByte(13);
            pos++;
          case 0x74:
            buffer.addByte(9);
            pos++;
          case 0x62:
            buffer.addByte(8);
            pos++;
          case 0x66:
            buffer.addByte(12);
            pos++;
          case 0x28:
          case 0x29:
          case 0x5C:
            buffer.addByte(esc);
            pos++;
          case 10:
            pos++; // line continuation
          case 13:
            pos++;
            if (pos < length && bytes[pos] == 10) pos++;
          default:
            if (esc >= 0x30 && esc <= 0x37) {
              var value = 0;
              var digits = 0;
              while (digits < 3 && pos < length && bytes[pos] >= 0x30 && bytes[pos] <= 0x37) {
                value = value * 8 + (bytes[pos] - 0x30);
                pos++;
                digits++;
              }
              buffer.addByte(value & 0xFF);
            } else {
              buffer.addByte(esc);
              pos++;
            }
        }
        continue;
      }
      if (b == 0x28) {
        depth++;
        buffer.addByte(b);
        pos++;
        continue;
      }
      if (b == 0x29) {
        depth--;
        pos++;
        if (depth == 0) break;
        buffer.addByte(b);
        continue;
      }
      buffer.addByte(b);
      pos++;
    }
    return PdfToken(
      PdfTokenType.string,
      bytes: buffer.toBytes(),
      start: start,
      end: pos,
    );
  }

  PdfToken _readHexString() {
    final start = pos;
    pos++; // skip '<'
    final hexDigits = StringBuffer();
    while (pos < length && bytes[pos] != 0x3E) {
      final b = bytes[pos];
      if (!_isWhitespace(b)) hexDigits.write(String.fromCharCode(b));
      pos++;
    }
    if (pos < length) pos++; // skip '>'
    var hex = hexDigits.toString();
    if (hex.length.isOdd) hex += '0';
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return PdfToken(PdfTokenType.string, bytes: out, start: start, end: pos);
  }

  PdfToken _readNumberOrKeyword() {
    final start = pos;
    final buffer = StringBuffer();
    if (bytes[pos] == 0x2B || bytes[pos] == 0x2D) {
      buffer.writeCharCode(bytes[pos]);
      pos++;
    }
    var sawDigitOrDot = false;
    while (pos < length) {
      final b = bytes[pos];
      if ((b >= 0x30 && b <= 0x39) || b == 0x2E) {
        sawDigitOrDot = true;
        buffer.writeCharCode(b);
        pos++;
      } else {
        break;
      }
    }
    if (!sawDigitOrDot) {
      // Lone '+'/'-' followed by non-digit: treat as a keyword token.
      while (pos < length && !_isWhitespace(bytes[pos]) && !_isDelimiter(bytes[pos])) {
        buffer.writeCharCode(bytes[pos]);
        pos++;
      }
      return PdfToken(PdfTokenType.keyword, text: buffer.toString(), start: start, end: pos);
    }
    final value = num.tryParse(buffer.toString()) ?? 0;
    return PdfToken(PdfTokenType.number, number: value, start: start, end: pos);
  }

  PdfToken _readKeyword() {
    final start = pos;
    final buffer = StringBuffer();
    while (pos < length && !_isWhitespace(bytes[pos]) && !_isDelimiter(bytes[pos])) {
      buffer.writeCharCode(bytes[pos]);
      pos++;
    }
    if (buffer.isEmpty) {
      // Unrecognized delimiter (e.g. stray '{' in content streams); skip it.
      pos++;
      return PdfToken(PdfTokenType.keyword, text: String.fromCharCode(bytes[start]), start: start, end: pos);
    }
    return PdfToken(PdfTokenType.keyword, text: buffer.toString(), start: start, end: pos);
  }
}
