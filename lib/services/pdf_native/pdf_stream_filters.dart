import 'dart:io';
import 'dart:typed_data';

/// Reverses PNG-style predictors (types 10-15, used with /Predictor >= 10
/// alongside FlateDecode) applied by most PDF producers to font and
/// xref streams to improve compression.
Uint8List undoPngPredictor(
  Uint8List data, {
  required int columns,
  required int colors,
  required int bitsPerComponent,
}) {
  final bytesPerPixel = ((colors * bitsPerComponent) + 7) ~/ 8;
  final rowBytes = ((colors * bitsPerComponent * columns) + 7) ~/ 8;
  final out = BytesBuilder();
  var previous = Uint8List(rowBytes);
  var offset = 0;
  while (offset + 1 + rowBytes <= data.length) {
    final filterType = data[offset];
    final row = Uint8List.fromList(
      data.sublist(offset + 1, offset + 1 + rowBytes),
    );
    for (var i = 0; i < rowBytes; i++) {
      final a = i >= bytesPerPixel ? row[i - bytesPerPixel] : 0;
      final b = previous[i];
      final c = i >= bytesPerPixel ? previous[i - bytesPerPixel] : 0;
      switch (filterType) {
        case 0:
          break;
        case 1:
          row[i] = (row[i] + a) & 0xFF;
        case 2:
          row[i] = (row[i] + b) & 0xFF;
        case 3:
          row[i] = (row[i] + ((a + b) >> 1)) & 0xFF;
        case 4:
          row[i] = (row[i] + _paeth(a, b, c)) & 0xFF;
        default:
          break;
      }
    }
    out.add(row);
    previous = row;
    offset += 1 + rowBytes;
  }
  return out.toBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// Inflates zlib/Flate-compressed stream bytes. Returns null (rather than
/// throwing) on malformed data so callers can skip an undecodable stream
/// without aborting the whole document parse.
Uint8List? inflate(Uint8List bytes) {
  try {
    return Uint8List.fromList(zlib.decode(bytes));
  } on Object {
    return null;
  }
}

Uint8List decodeAscii85(Uint8List bytes) {
  final out = BytesBuilder();
  final group = <int>[];
  var i = 0;
  // Skip a leading '<~' delimiter if present.
  if (bytes.length >= 2 && bytes[0] == 0x3C && bytes[1] == 0x7E) i = 2;
  for (; i < bytes.length; i++) {
    final b = bytes[i];
    if (b == 0x7E) break; // '~' end marker
    if (b == 0x7A && group.isEmpty) {
      out.add(Uint8List(4));
      continue;
    }
    if (b < 0x21 || b > 0x75) continue; // whitespace/invalid, skip
    group.add(b - 0x21);
    if (group.length == 5) {
      _flushAscii85Group(group, out, 4);
      group.clear();
    }
  }
  if (group.isNotEmpty) {
    final padCount = 5 - group.length;
    group.addAll(List.filled(padCount, 84));
    _flushAscii85Group(group, out, 4 - padCount);
  }
  return out.toBytes();
}

void _flushAscii85Group(List<int> group, BytesBuilder out, int outputBytes) {
  var value = 0;
  for (final digit in group) {
    value = value * 85 + digit;
  }
  final bytes = Uint8List(4)
    ..[0] = (value >> 24) & 0xFF
    ..[1] = (value >> 16) & 0xFF
    ..[2] = (value >> 8) & 0xFF
    ..[3] = value & 0xFF;
  out.add(bytes.sublist(0, outputBytes));
}
