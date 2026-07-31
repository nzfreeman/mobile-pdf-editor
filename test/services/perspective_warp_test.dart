import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_pdf_editor/services/perspective_warp.dart';

void main() {
  test('computeHomography maps each source point exactly to its destination', () {
    const src = [
      Point2D(10, 20),
      Point2D(300, 15),
      Point2D(290, 400),
      Point2D(5, 380),
    ];
    const dst = [
      Point2D(0, 0),
      Point2D(200, 0),
      Point2D(200, 300),
      Point2D(0, 300),
    ];
    final h = computeHomography(src, dst);

    for (var i = 0; i < 4; i++) {
      final denom = h[6] * src[i].x + h[7] * src[i].y + h[8];
      final x = (h[0] * src[i].x + h[1] * src[i].y + h[2]) / denom;
      final y = (h[3] * src[i].x + h[4] * src[i].y + h[5]) / denom;
      expect(x, closeTo(dst[i].x, 0.01));
      expect(y, closeTo(dst[i].y, 0.01));
    }
  });

  test('warping an axis-aligned quad matching the full image is a no-op crop', () {
    final src = img.Image(width: 100, height: 80);
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        src.setPixel(x, y, img.ColorRgb8(x * 2, y * 3, 128));
      }
    }
    final quad = [
      const Point2D(0, 0),
      const Point2D(100, 0),
      const Point2D(100, 80),
      const Point2D(0, 80),
    ];
    final warped = warpPerspective(
      src: src,
      srcQuad: quad,
      outputWidth: 100,
      outputHeight: 80,
    );

    expect(warped.width, 100);
    expect(warped.height, 80);
    final samplePoints = [(10, 10), (50, 40), (99, 79), (0, 0)];
    for (final (x, y) in samplePoints) {
      final original = src.getPixel(x, y);
      final result = warped.getPixel(x, y);
      expect(result.r, closeTo(original.r, 1));
      expect(result.g, closeTo(original.g, 1));
      expect(result.b, closeTo(original.b, 1));
    }
  });

  test('warping a skewed quad straightens it to the target rectangle size', () {
    final src = img.Image(width: 400, height: 400);
    img.fill(src, color: img.ColorRgb8(10, 10, 10));
    // A white square drawn as a skewed quad's exact interior, so the
    // rectified output should be uniformly white.
    final quad = [
      const Point2D(50, 60),
      const Point2D(350, 40),
      const Point2D(370, 380),
      const Point2D(30, 360),
    ];
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        if (_pointInQuad(x.toDouble(), y.toDouble(), quad)) {
          src.setPixel(x, y, img.ColorRgb8(255, 255, 255));
        }
      }
    }

    final warped = warpPerspective(
      src: src,
      srcQuad: quad,
      outputWidth: 200,
      outputHeight: 200,
    );

    // Sample well inside the rectified output, away from edge aliasing.
    for (final (x, y) in [(20, 20), (100, 100), (180, 180), (180, 20)]) {
      final pixel = warped.getPixel(x, y);
      expect(pixel.r, greaterThan(200));
    }
  });
}

bool _pointInQuad(double x, double y, List<Point2D> quad) {
  var inside = false;
  for (var i = 0, j = quad.length - 1; i < quad.length; j = i++) {
    final xi = quad[i].x, yi = quad[i].y;
    final xj = quad[j].x, yj = quad[j].y;
    final intersects =
        ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi);
    if (intersects) inside = !inside;
  }
  return inside;
}
