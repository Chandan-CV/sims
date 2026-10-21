import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'constants.dart';

enum ImageCropMode {
  centerCrop,
  letterbox,
}

class ImagePreprocessor {
  /// Preprocesses image bytes into a float32 tensor of shape [1, 3, 224, 224] in CHW format.
  ///
  /// - [ImageCropMode.centerCrop]: Standard CLIP preprocessing matching Hugging Face
  ///   CLIPImageProcessor (resizes shorter side to 224, center-crops to square).
  /// - [ImageCropMode.letterbox]: Preserves 100% of the image field-of-view without cropping
  ///   by resizing the longer side to 224 and padding the canvas with normalized mean (0.0).
  static Float32List preprocess(
    Uint8List bytes, {
    ImageCropMode cropMode = ImageCropMode.centerCrop,
  }) {
    var decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('Failed to decode image');

    if (cropMode == ImageCropMode.letterbox) {
      return _preprocessLetterbox(decoded);
    }
    return _preprocessCenterCrop(decoded);
  }

  static Float32List _preprocessCenterCrop(img.Image decoded) {
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

  static Float32List _preprocessLetterbox(img.Image decoded) {
    final double scale = (decoded.width > decoded.height)
        ? kImageSize / decoded.width
        : kImageSize / decoded.height;

    final targetW = (decoded.width * scale).round().clamp(1, kImageSize);
    final targetH = (decoded.height * scale).round().clamp(1, kImageSize);

    final resized = img.copyResize(
      decoded,
      width: targetW,
      height: targetH,
      interpolation: img.Interpolation.cubic,
    );

    final padX = (kImageSize - targetW) ~/ 2;
    final padY = (kImageSize - targetH) ~/ 2;

    const plane = kImageSize * kImageSize;
    final tensor = Float32List(3 * plane);

    // Padding values are naturally 0.0 in Float32List, matching normalized mean: (mean - mean)/std = 0.
    for (int h = 0; h < targetH; h++) {
      for (int w = 0; w < targetW; w++) {
        final pixel = resized.getPixel(w, h);
        final offset = (padY + h) * kImageSize + (padX + w);
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
