// Model release base URL for ONNX models.
const String kModelReleaseBaseUrl =
    'https://github.com/Chandan-CV/sims/releases/download/v0.0.2';

/// Configuration profile for vision backbones (CLIP, SigLIP, etc.)
class VisionBackboneConfig {
  final String id;
  final String displayName;
  final String imageEncoderFilename;
  final String textEncoderFilename;
  final int embeddingDim;
  final int maxTokenLength;
  final int imageSize;
  final List<double> imageMean;
  final List<double> imageStd;

  const VisionBackboneConfig({
    required this.id,
    required this.displayName,
    required this.imageEncoderFilename,
    required this.textEncoderFilename,
    required this.embeddingDim,
    required this.maxTokenLength,
    required this.imageSize,
    required this.imageMean,
    required this.imageStd,
  });

  /// Default: OpenAI CLIP ViT-B/32 (int8 quantized).
  static const clipVitB32 = VisionBackboneConfig(
    id: 'clip_vit_b32',
    displayName: 'OpenAI CLIP ViT-B/32',
    imageEncoderFilename: 'clip_vit_b32_image_int8.onnx',
    textEncoderFilename: 'clip_vit_b32_text_int8.onnx',
    embeddingDim: 512,
    maxTokenLength: 77,
    imageSize: 224,
    imageMean: [0.48145466, 0.4578275, 0.40821073],
    imageStd: [0.26862954, 0.26130258, 0.27577711],
  );

  /// Fine-grained: OpenAI CLIP ViT-B/16 (16x16 patch size).
  static const clipVitB16 = VisionBackboneConfig(
    id: 'clip_vit_b16',
    displayName: 'OpenAI CLIP ViT-B/16',
    imageEncoderFilename: 'clip_vit_b16_image_int8.onnx',
    textEncoderFilename: 'clip_vit_b16_text_int8.onnx',
    embeddingDim: 512,
    maxTokenLength: 77,
    imageSize: 224,
    imageMean: [0.48145466, 0.4578275, 0.40821073],
    imageStd: [0.26862954, 0.26130258, 0.27577711],
  );

  /// Advanced zero-shot retrieval: Google SigLIP Base Patch 16.
  static const siglipBasePatch16 = VisionBackboneConfig(
    id: 'siglip_b16',
    displayName: 'Google SigLIP Base Patch 16',
    imageEncoderFilename: 'siglip_base_patch16_image_int8.onnx',
    textEncoderFilename: 'siglip_base_patch16_text_int8.onnx',
    embeddingDim: 768,
    maxTokenLength: 64,
    imageSize: 224,
    imageMean: [0.5, 0.5, 0.5],
    imageStd: [0.5, 0.5, 0.5],
  );
}

// Active vision model configuration.
const VisionBackboneConfig kActiveBackbone = VisionBackboneConfig.clipVitB32;

const String kImageEncoderFilename = kActiveBackbone.imageEncoderFilename;
const String kTextEncoderFilename = kActiveBackbone.textEncoderFilename;
const String kImageEncoderUrl = '$kModelReleaseBaseUrl/$kImageEncoderFilename';
const String kTextEncoderUrl = '$kModelReleaseBaseUrl/$kTextEncoderFilename';

// Approximate combined download size, shown on the download screen.
const String kModelDownloadSizeLabel = '~200 MB';

const String kDbFilename = 'sims.db';

const int kEmbeddingDim = kActiveBackbone.embeddingDim;
const int kMaxTokenLength = kActiveBackbone.maxTokenLength;
const int kImageSize = kActiveBackbone.imageSize;
const int kSearchTopK = 200;
const int kSearchPageSize = 50;

// How many images are stacked into a single ONNX image-encoder call during
// indexing (the exported model has a dynamic batch dimension — see
// ModelService.encodeImages). Bigger batches amortise the fixed per-call
// (platform channel + session) overhead over more images.
const int kIndexBatchSize = 10;

// photo_manager caches every thumbnailDataWithSize() result to disk
// (cache/image_manager_disk_cache) and never clears it on its own —
// indexing touches every photo in the library once, so left unchecked
// this grows to roughly one cached thumbnail per photo. Cleared every
// this many batches during a run (and once more at the end) to keep it
// bounded instead of accumulating for the whole library.
const int kCacheClearIntervalBatches = 50;

// Normalisation constants for active vision backbone
const List<double> kImageMean = kActiveBackbone.imageMean;
const List<double> kImageStd = kActiveBackbone.imageStd;

// "Run in background" one-off indexing task, handed off from IndexingScreen
// (see BackgroundIndexService). Android only.
const String kIndexNowTaskId = 'sims.indexNow';
const String kIndexNowTaskName = 'sims.indexNow';

// The background task's heartbeat, so the UI isolate can tell "still
// running" apart from "the OS killed it without cleaning up after itself".
// Stored in DatabaseService's meta table — both isolates open the same
// SQLite file, so no SharedPreferences is needed just for this.
const String kMetaBgIndexHeartbeatMillis = 'bg_index_heartbeat_millis';
const Duration kBgIndexStaleAfter = Duration(minutes: 2);

// Progress notification shown while the "index now" task runs.
const String kIndexingNotificationChannelId = 'sims_indexing';
const String kIndexingNotificationChannelName = 'Photo indexing';
const int kIndexingNotificationId = 4201;
