import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'constants.dart';

class ImagePreprocessor {
  static Float32List preprocess(Uint8List bytes) {
    var decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('Failed to decode image');

    // Center-crop to square then resize to model input size
    final minSide = decoded.width < decoded.height ? decoded.width : decoded.height;
    final x = (decoded.width - minSide) ~/ 2;
    final y = (decoded.height - minSide) ~/ 2;
    final cropped = img.copyCrop(decoded, x: x, y: y, width: minSide, height: minSide);
    final resized = img.copyResize(cropped, width: kImageSize, height: kImageSize,
        interpolation: img.Interpolation.linear);

    // Convert to float32 tensor in CHW format [1, 3, 256, 256] and normalise
    final tensor = Float32List(3 * kImageSize * kImageSize);
    for (int h = 0; h < kImageSize; h++) {
      for (int w = 0; w < kImageSize; w++) {
        final pixel = resized.getPixel(w, h);
        final offset = h * kImageSize + w;
        tensor[0 * kImageSize * kImageSize + offset] = pixel.r / 255.0;
        tensor[1 * kImageSize * kImageSize + offset] = pixel.g / 255.0;
        tensor[2 * kImageSize * kImageSize + offset] = pixel.b / 255.0;
      }
    }
    return tensor;
  }
}
