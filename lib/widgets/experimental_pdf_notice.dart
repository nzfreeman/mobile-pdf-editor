import 'package:flutter/material.dart';

/// Shown before a user's first use, per screen, of a feature built on
/// this app's own from-scratch PDF parser/writer (native text edit,
/// forms, structure-preserving merge/split). That reader intentionally
/// covers only common cases (see pdf_native/*.dart doc comments for
/// specifics — encrypted PDFs, some stream filters, multi-content-
/// stream/rotated/linearized/signed documents, ligatures and non-
/// Identity CMaps, etc. aren't all handled) — this keeps that limitation
/// visible in the UI rather than only in code comments, and reassures
/// users of the two guarantees that *are* always true regardless of
/// input: output always goes to a new file, and the on-screen preview
/// always reflects exactly what would be saved.
Future<bool> showExperimentalPdfNotice(
  BuildContext context, {
  required String featureName,
}) async {
  final proceed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('실험적 기능 안내'),
      content: Text(
        '$featureName 기능은 PDF 내부 구조를 직접 읽고 쓰는 실험적 기능입니다.\n\n'
        '• 암호화된 PDF, 일부 압축·인코딩 방식, 복잡한 텍스트 배치(세로쓰기, 합자, '
        '리가처 등)가 있는 문서는 지원하지 않거나 예상과 다르게 처리될 수 있습니다.\n'
        '• 결과는 항상 새 파일로 저장되며, 원본 파일은 변경되지 않습니다.\n'
        '• 저장하기 전에 화면의 미리보기를 꼭 확인하세요.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('확인하고 계속'),
        ),
      ],
    ),
  );
  return proceed ?? false;
}
