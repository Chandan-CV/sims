// OpenAI CLIP ViT-B/32, int8-quantized ONNX (produced by tools/export_clip).
// Model download URLs — upload the two files in tools/export_clip/out/ to this
// GitHub release.
const String kModelReleaseBaseUrl =
    'https://github.com/Chandan-CV/sims/releases/download/v0.0.2';
const String kImageEncoderFilename = 'clip_vit_b32_image_int8.onnx';
const String kTextEncoderFilename = 'clip_vit_b32_text_int8.onnx';
const String kImageEncoderUrl = '$kModelReleaseBaseUrl/$kImageEncoderFilename';
const String kTextEncoderUrl = '$kModelReleaseBaseUrl/$kTextEncoderFilename';

// SHA-256 checksums for verifying downloaded model integrity.
const String kImageEncoderSha256 =
    'afea268d2aca96809bcd5f2392f62499489a2709dd0565921612e2bb934b378e';
const String kTextEncoderSha256 =
    '982aa3c29c9483a69592b4947a6c363f06d67eebe66394f29d42cff0d93f0ce0';

// Approximate combined download size, shown on the download screen.
const String kModelDownloadSizeLabel = '~200 MB';

const String kDbFilename = 'sims.db';

const int kEmbeddingDim = 512;
const int kMaxTokenLength = 77;
const int kImageSize = 224;
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

// OpenAI CLIP normalisation constants (applied in ImagePreprocessor)
const List<double> kImageMean = [0.48145466, 0.4578275, 0.40821073];
const List<double> kImageStd = [0.26862954, 0.26130258, 0.27577711];

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
