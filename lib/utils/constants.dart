// Model download URLs — replace with your GitHub release links
const String kImageEncoderUrl = 'https://github.com/Chandan-CV/sims/releases/download/v0.0.1/image_encoder.onnx';
const String kTextEncoderUrl = 'https://github.com/Chandan-CV/sims/releases/download/v0.0.1/text_encoder.onnx';

const String kImageEncoderFilename = 'image_encoder.onnx';
const String kTextEncoderFilename = 'text_encoder.onnx';
const String kDbFilename = 'sims.db';

const int kEmbeddingDim = 512;
const int kMaxTokenLength = 77;
const int kImageSize = 256;
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

// MobileCLIP / CLIP normalisation constants
const List<double> kImageMean = [0.48145466, 0.4578275, 0.40821073];
const List<double> kImageStd = [0.26862954, 0.26130258, 0.27577711];
