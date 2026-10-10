import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'constants.dart';

class ImagePreprocessor {
  static Float32List preprocess(Uint8List bytes) {
    var decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('Failed to decode image');

    // CLIP preprocessing: resize the shorter side to the model input size
    // (bicubic), then center-crop to a square.
    final resized = decoded.width < decoded.height
        ? img.copyResize(decoded,
            width: kImageSize, interpolation: img.Interpolation.cubic)
        : img.copyResize(decoded,
            height: kImageSize, interpolation: img.Interpolation.cubic);
    final x = (resized.width - kImageSize) ~/ 2;
    final y = (resized.height - kImageSize) ~/ 2;
    final cropped = img.copyCrop(resized,
        x: x, y: y, width: kImageSize, height: kImageSize);

    // Convert to float32 tensor in CHW format [1, 3, 224, 224], scaled to
    // 0..1 and normalised with CLIP's per-channel mean/std.
    const plane = kImageSize * kImageSize;
    final tensor = Float32List(3 * plane);
    for (int h = 0; h < kImageSize; h++) {
      for (int w = 0; w < kImageSize; w++) {
        final pixel = cropped.getPixel(w, h);
        final offset = h * kImageSize + w;
        tensor[offset] = (pixel.r / 255.0 - kImageMean[0]) / kImageStd[0];
        tensor[plane + offset] =
            (pixel.g / 255.0 - kImageMean[1]) / kImageStd[1];
        tensor[2 * plane + offset] =
            (pixel.b / 255.0 - kImageMean[2]) / kImageStd[2];
      }
    }
    return tensor;
  }
}
