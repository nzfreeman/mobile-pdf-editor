import 'dart:math' as math;

import 'package:image/image.dart' as img;

class Point2D {
  const Point2D(this.x, this.y);
  final double x;
  final double y;

  double distanceTo(Point2D other) =>
      math.sqrt(math.pow(x - other.x, 2) + math.pow(y - other.y, 2));
}

/// Solves the 3x3 projective transform (as a flat row-major 9-element
/// list, with the last element normalized to 1) mapping each `src[i]` to
/// `dst[i]` for exactly 4 point correspondences, via the standard direct
/// linear transform: 8 unknowns (the 9th, h33, is fixed to 1), 8 linear
/// equations (2 per correspondence), solved by Gaussian elimination with
/// partial pivoting.
List<double> computeHomography(List<Point2D> src, List<Point2D> dst) {
  assert(src.length == 4 && dst.length == 4);
  final a = List.generate(8, (_) => List<double>.filled(8, 0));
  final b = List<double>.filled(8, 0);

  for (var i = 0; i < 4; i++) {
    final sx = src[i].x, sy = src[i].y;
    final dx = dst[i].x, dy = dst[i].y;
    a[2 * i] = [sx, sy, 1, 0, 0, 0, -sx * dx, -sy * dx];
    b[2 * i] = dx;
    a[2 * i + 1] = [0, 0, 0, sx, sy, 1, -sx * dy, -sy * dy];
    b[2 * i + 1] = dy;
  }

  final h = _solveLinearSystem(a, b);
  return [...h, 1.0];
}

List<double> _solveLinearSystem(List<List<double>> a, List<double> b) {
  final n = b.length;
  final m = List.generate(n, (i) => [...a[i], b[i]]);

  for (var col = 0; col < n; col++) {
    var pivot = col;
    for (var row = col + 1; row < n; row++) {
      if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
    }
    final tmp = m[col];
    m[col] = m[pivot];
    m[pivot] = tmp;

    final pivotValue = m[col][col];
    if (pivotValue.abs() < 1e-12) continue; // singular; leave as best-effort
    for (var row = 0; row < n; row++) {
      if (row == col) continue;
      final factor = m[row][col] / pivotValue;
      if (factor == 0) continue;
      for (var k = col; k <= n; k++) {
        m[row][k] -= factor * m[col][k];
      }
    }
  }

  return List.generate(n, (i) {
    final pivotValue = m[i][i];
    if (pivotValue.abs() < 1e-12) return 0.0;
    return m[i][n] / pivotValue;
  });
}

/// Rectifies the quadrilateral [srcQuad] (four corners of the document in
/// [src], ordered top-left, top-right, bottom-right, bottom-left) into a
/// straight `outputWidth`x`outputHeight` image — the standard
/// "inverse warp" approach: for every output pixel, map backward into
/// source-image space (via the dst->src homography directly, avoiding a
/// separate matrix-inversion step) and bilinearly sample.
img.Image warpPerspective({
  required img.Image src,
  required List<Point2D> srcQuad,
  required int outputWidth,
  required int outputHeight,
}) {
  final dstCorners = [
    const Point2D(0, 0),
    Point2D(outputWidth.toDouble(), 0),
    Point2D(outputWidth.toDouble(), outputHeight.toDouble()),
    Point2D(0, outputHeight.toDouble()),
  ];
  // Solved directly as dst -> src, so each output pixel's source
  // coordinate is one matrix application away with no separate inverse.
  final matrix = computeHomography(dstCorners, srcQuad);

  final output = img.Image(width: outputWidth, height: outputHeight);
  for (var y = 0; y < outputHeight; y++) {
    for (var x = 0; x < outputWidth; x++) {
      final denom = matrix[6] * x + matrix[7] * y + matrix[8];
      if (denom == 0) continue;
      final sx = (matrix[0] * x + matrix[1] * y + matrix[2]) / denom;
      final sy = (matrix[3] * x + matrix[4] * y + matrix[5]) / denom;
      _bilinearSample(output, x, y, src, sx, sy);
    }
  }
  return output;
}

void _bilinearSample(
  img.Image output,
  int outX,
  int outY,
  img.Image src,
  double x,
  double y,
) {
  final x0 = x.floor().clamp(0, src.width - 1);
  final y0 = y.floor().clamp(0, src.height - 1);
  final x1 = (x0 + 1).clamp(0, src.width - 1);
  final y1 = (y0 + 1).clamp(0, src.height - 1);
  final fx = (x - x0).clamp(0.0, 1.0);
  final fy = (y - y0).clamp(0.0, 1.0);

  final p00 = src.getPixel(x0, y0);
  final p10 = src.getPixel(x1, y0);
  final p01 = src.getPixel(x0, y1);
  final p11 = src.getPixel(x1, y1);

  double lerp(num a, num b, double t) => a + (b - a) * t;
  final r = lerp(lerp(p00.r, p10.r, fx), lerp(p01.r, p11.r, fx), fy);
  final g = lerp(lerp(p00.g, p10.g, fx), lerp(p01.g, p11.g, fx), fy);
  final bch = lerp(lerp(p00.b, p10.b, fx), lerp(p01.b, p11.b, fx), fy);

  output.setPixelRgb(outX, outY, r.round(), g.round(), bch.round());
}
