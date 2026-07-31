import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../services/perspective_warp.dart';

/// Lets the user drag the four corners of a captured photo to match a
/// (possibly tilted/skewed) document's actual edges, then rectifies that
/// quadrilateral into a straight rectangular image via a perspective
/// warp — the standard "scanner app" corner-adjustment step, which a
/// simple axis-aligned crop (the previous flow) can't achieve for a
/// photo taken at an angle.
class PerspectiveCropScreen extends StatefulWidget {
  const PerspectiveCropScreen({super.key, required this.imageFile});

  final File imageFile;

  @override
  State<PerspectiveCropScreen> createState() => _PerspectiveCropScreenState();
}

class _PerspectiveCropScreenState extends State<PerspectiveCropScreen> {
  static const _defaultCorners = [
    Offset(0.08, 0.08),
    Offset(0.92, 0.08),
    Offset(0.92, 0.92),
    Offset(0.08, 0.92),
  ];

  img.Image? _decoded;
  List<Offset> _corners = _defaultCorners;
  int? _draggingIndex;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.imageFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (mounted) setState(() => _decoded = decoded);
  }

  Future<void> _confirm() async {
    final decoded = _decoded;
    if (decoded == null) return;
    setState(() => _processing = true);
    try {
      final quad = _corners
          .map(
            (c) => Point2D(
              (c.dx * decoded.width).clamp(0, decoded.width.toDouble()),
              (c.dy * decoded.height).clamp(0, decoded.height.toDouble()),
            ),
          )
          .toList();

      final topWidth = quad[0].distanceTo(quad[1]);
      final bottomWidth = quad[3].distanceTo(quad[2]);
      final leftHeight = quad[0].distanceTo(quad[3]);
      final rightHeight = quad[1].distanceTo(quad[2]);
      final outputWidth = math.max(topWidth, bottomWidth).round().clamp(
        1,
        4000,
      );
      final outputHeight = math.max(leftHeight, rightHeight).round().clamp(
        1,
        4000,
      );

      final warped = warpPerspective(
        src: decoded,
        srcQuad: quad,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
      );

      final directory = await getApplicationDocumentsDirectory();
      final output = File(
        '${directory.path}/scan_rectified_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await output.writeAsBytes(img.encodeJpg(warped, quality: 92), flush: true);
      if (mounted) Navigator.pop(context, output);
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _updateCorner(int index, Size displaySize, Offset localPosition) {
    setState(() {
      final updated = [..._corners];
      updated[index] = Offset(
        (localPosition.dx / displaySize.width).clamp(0.0, 1.0),
        (localPosition.dy / displaySize.height).clamp(0.0, 1.0),
      );
      _corners = updated;
    });
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _decoded;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('모서리 맞추기'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _corners = _defaultCorners),
            child: const Text('초기화', style: TextStyle(color: Colors.white)),
          ),
          IconButton(
            onPressed: _processing ? null : _confirm,
            icon: const Icon(Icons.check, color: Colors.white),
            tooltip: '적용',
          ),
        ],
      ),
      body: decoded == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final aspectRatio = decoded.width / decoded.height;
                      var displayWidth = constraints.maxWidth;
                      var displayHeight = displayWidth / aspectRatio;
                      if (displayHeight > constraints.maxHeight) {
                        displayHeight = constraints.maxHeight;
                        displayWidth = displayHeight * aspectRatio;
                      }
                      final displaySize = Size(displayWidth, displayHeight);
                      final points = _corners
                          .map(
                            (c) => Offset(
                              c.dx * displayWidth,
                              c.dy * displayHeight,
                            ),
                          )
                          .toList();

                      return SizedBox(
                        width: displayWidth,
                        height: displayHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: Image.file(
                                widget.imageFile,
                                fit: BoxFit.fill,
                              ),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _QuadPainter(points),
                                ),
                              ),
                            ),
                            for (var i = 0; i < points.length; i++)
                              Positioned(
                                left: points[i].dx - 22,
                                top: points[i].dy - 22,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: (_) =>
                                      setState(() => _draggingIndex = i),
                                  onPanUpdate: (details) {
                                    final updated = points[i] + details.delta;
                                    _updateCorner(i, displaySize, updated);
                                  },
                                  onPanEnd: (_) =>
                                      setState(() => _draggingIndex = null),
                                  child: _handle(active: _draggingIndex == i),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                if (_processing)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x99000000),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text(
                              '보정 중...',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '문서의 네 모서리에 맞춰 점을 드래그하세요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.8)),
          ),
        ),
      ),
    );
  }

  Widget _handle({required bool active}) {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: active ? 26 : 20,
        height: active ? 26 : 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.amber.withValues(alpha: 0.9),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 4),
          ],
        ),
      ),
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.points);
  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length != 4) return;
    final linePaint = Paint()
      ..color = Colors.amber
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()..color = Colors.amber.withValues(alpha: 0.15);

    final path = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _QuadPainter oldDelegate) =>
      oldDelegate.points != points;
}
