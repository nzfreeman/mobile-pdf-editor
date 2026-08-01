import 'pdf_document.dart';
import 'pdf_form_fields.dart' show decodePdfTextString;
import 'pdf_objects.dart';

/// A single Link annotation (`/Subtype /Link`) extracted from a page,
/// resolved to either an external URL or a same-document page jump.
/// Annotations whose destination this reader can't resolve (named
/// destinations via the document's `/Names` tree, actions other than
/// `/URI`/`/GoTo`) are skipped rather than guessed at.
class PdfLinkAnnotation {
  const PdfLinkAnnotation({
    required this.pageIndex,
    required this.rectX,
    required this.rectY,
    required this.rectWidth,
    required this.rectHeight,
    this.uri,
    this.destPageIndex,
  });

  final int pageIndex;

  /// Normalized `[0,1]` rect in top-left-origin, y-down UI space (same
  /// convention as `EditorItem.x/y/width/height`), derived from the
  /// annotation's `/Rect` (bottom-left-origin, y-up PDF user space) and
  /// the page's `MediaBox`.
  final double rectX;
  final double rectY;
  final double rectWidth;
  final double rectHeight;

  /// Set when the link opens an external URL.
  final String? uri;

  /// Set when the link jumps to another page in the same document.
  final int? destPageIndex;
}

List<double> _normalizeBox(List<double> box) {
  if (box.length < 4) return [0.0, 0.0, 612.0, 792.0];
  final x0 = box[0] < box[2] ? box[0] : box[2];
  final x1 = box[0] < box[2] ? box[2] : box[0];
  final y0 = box[1] < box[3] ? box[1] : box[3];
  final y1 = box[1] < box[3] ? box[3] : box[1];
  return [x0, y0, x1, y1];
}

List<double> _mediaBoxOf(PdfDocument doc, PdfDictionaryObj page) {
  final mediaBoxObj = doc.inheritedAttribute(page, 'MediaBox');
  return _normalizeBox(
    mediaBoxObj is PdfArrayObj
        ? mediaBoxObj.items
              .map((o) => (doc.resolve(o) as PdfNumber?)?.doubleValue ?? 0.0)
              .toList()
        : [0.0, 0.0, 612.0, 792.0],
  );
}

/// Extracts every readable Link annotation across all pages of [doc].
List<PdfLinkAnnotation> extractLinkAnnotations(PdfDocument doc) {
  final pages = doc.pages;
  final pageIndexByIdentity = <PdfDictionaryObj, int>{
    for (var i = 0; i < pages.length; i++) pages[i]: i,
  };
  final result = <PdfLinkAnnotation>[];

  for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    final page = pages[pageIndex];
    final annotsObj = doc.resolve(page['Annots']);
    if (annotsObj is! PdfArrayObj) continue;
    final mediaBox = _mediaBoxOf(doc, page);
    final pageWidth = mediaBox[2] - mediaBox[0];
    final pageHeight = mediaBox[3] - mediaBox[1];
    if (pageWidth <= 0 || pageHeight <= 0) continue;

    for (final annotRef in annotsObj.items) {
      final annot = doc.resolve(annotRef);
      if (annot is! PdfDictionaryObj) continue;
      final subtype = (doc.resolve(annot['Subtype']) as PdfName?)?.value;
      if (subtype != 'Link') continue;

      final rectObj = doc.resolve(annot['Rect']);
      if (rectObj is! PdfArrayObj || rectObj.items.length < 4) continue;
      final rect = _normalizeBox(
        rectObj.items
            .map((o) => (doc.resolve(o) as PdfNumber?)?.doubleValue ?? 0.0)
            .toList(),
      );

      String? uri;
      int? destPageIndex;

      final action = doc.resolve(annot['A']);
      if (action is PdfDictionaryObj) {
        final actionType = (doc.resolve(action['S']) as PdfName?)?.value;
        if (actionType == 'URI') {
          final uriObj = doc.resolve(action['URI']);
          if (uriObj is PdfLiteralString) {
            uri = decodePdfTextString(uriObj.bytes);
          }
        } else if (actionType == 'GoTo') {
          destPageIndex = _resolveGoToPageIndex(
            doc,
            action['D'],
            pageIndexByIdentity,
          );
        }
      } else {
        // Direct /Dest on the annotation (no /A action dictionary).
        destPageIndex = _resolveGoToPageIndex(
          doc,
          annot['Dest'],
          pageIndexByIdentity,
        );
      }

      if (uri == null && destPageIndex == null) continue;

      result.add(
        PdfLinkAnnotation(
          pageIndex: pageIndex,
          rectX: (rect[0] - mediaBox[0]) / pageWidth,
          rectY: (mediaBox[3] - rect[3]) / pageHeight,
          rectWidth: (rect[2] - rect[0]) / pageWidth,
          rectHeight: (rect[3] - rect[1]) / pageHeight,
          uri: uri,
          destPageIndex: destPageIndex,
        ),
      );
    }
  }

  return result;
}

/// Only the direct-array destination form (`[pageRef /XYZ ...]`) is
/// supported — named destinations (a `/Name` or string looked up via the
/// document's `/Names` tree) are a distinct, less common feature and are
/// skipped rather than mis-resolved.
int? _resolveGoToPageIndex(
  PdfDocument doc,
  PdfObject? destObj,
  Map<PdfDictionaryObj, int> pageIndexByIdentity,
) {
  final dest = doc.resolve(destObj);
  if (dest is! PdfArrayObj || dest.items.isEmpty) return null;
  final pageTarget = doc.resolve(dest.items.first);
  if (pageTarget is! PdfDictionaryObj) return null;
  return pageIndexByIdentity[pageTarget];
}
