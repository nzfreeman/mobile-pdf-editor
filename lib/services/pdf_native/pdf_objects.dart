import 'dart:typed_data';

/// Minimal PDF object model: just enough of the COS (Carousel Object
/// System) types to read xref tables, trailers, page/font dictionaries,
/// and decode content streams.
sealed class PdfObject {
  const PdfObject();
}

class PdfNull extends PdfObject {
  const PdfNull();
}

class PdfBool extends PdfObject {
  const PdfBool(this.value);
  final bool value;
}

class PdfNumber extends PdfObject {
  const PdfNumber(this.value);
  final num value;

  int get intValue => value.toInt();
  double get doubleValue => value.toDouble();
}

/// A PDF name, e.g. `/Font`. Stored without the leading slash.
class PdfName extends PdfObject {
  const PdfName(this.value);
  final String value;

  @override
  bool operator ==(Object other) => other is PdfName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '/$value';
}

/// A PDF literal or hex string, decoded to raw bytes (not text — encoding
/// is font-dependent and handled by [PdfFontInfo]).
class PdfLiteralString extends PdfObject {
  const PdfLiteralString(this.bytes);
  final Uint8List bytes;
}

class PdfArrayObj extends PdfObject {
  const PdfArrayObj(this.items);
  final List<PdfObject> items;
}

class PdfDictionaryObj extends PdfObject {
  const PdfDictionaryObj(this.entries);
  final Map<String, PdfObject> entries;

  PdfObject? operator [](String key) => entries[key];
}

/// An indirect reference, e.g. `12 0 R`.
class PdfRef extends PdfObject {
  const PdfRef(this.objectNumber, this.generation);
  final int objectNumber;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is PdfRef &&
      other.objectNumber == objectNumber &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(objectNumber, generation);

  @override
  String toString() => '$objectNumber $generation R';
}

/// A stream object: its dictionary plus the raw (still-encoded) bytes.
class PdfStreamObj extends PdfObject {
  const PdfStreamObj(this.dict, this.rawBytes);
  final PdfDictionaryObj dict;
  final Uint8List rawBytes;
}

extension PdfObjectHelpers on PdfObject? {
  /// Resolves this object through [resolve] if it's an indirect reference,
  /// otherwise returns it unchanged.
  PdfObject? resolveWith(PdfObject? Function(PdfRef) resolve) {
    final self = this;
    if (self is PdfRef) return resolve(self);
    return self;
  }
}
