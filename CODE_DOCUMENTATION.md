# SIMS — Code Documentation & Architecture Reference

> Status snapshot as of 2026-07-23. This documents the **actual, as-built code**, not the aspirational V2 plan. Where the implementation diverges from the "V2 Architecture & Implementation Plan" note, it's called out explicitly.

## 1. What this app does

SIMS (Semantic Image Search) is a Flutter app that lets a user search their on-device photo gallery using natural-language queries ("sunset at the beach", "my dog"), entirely offline. It works by:

1. Downloading two ONNX models (a CLIP-style image encoder and text encoder) from a GitHub release on first run.
2. Indexing every photo on the device: each photo is preprocessed and pushed through the image encoder to get a 512-dim embedding, stored in a local libSQL (Turso-compatible) database with native vector search.
3. On search, the query string is tokenized (CLIP BPE tokenizer) and encoded via the text encoder into the same 512-dim embedding space, then compared against stored image embeddings with a vector k-NN query.

Everything — model inference, tokenization, embedding storage, and search — runs on-device. No network calls happen except the one-time model download.

## 2. Actual tech stack (vs. what was planned)

| Concern | V2 plan said | Code actually uses |
|---|---|---|
| State management | Riverpod or BLoC | **None** — plain `StatefulWidget` + `setState` everywhere |
| Concurrency | Dart Isolates for preprocessing/inference/DB writes | **None** — everything runs on the main isolate, `await`ed inline |
| DB / vector store | Turso embedded replica, `vector_distance_cos` | `libsql_dart` local file DB (no remote replica/sync), `vector_top_k` + `libsql_vector_idx` |
| Schema | `image_index(asset_id PK, file_path, timestamp, embedding)` | `images(id PK, asset_id, embedding)` — no file_path or timestamp columns |
| Background sync | Periodic delta-sync listener for gallery changes | **None** — indexing is a manual, user-triggered, one-shot pass; re-opening the Indexing screen just re-scans for unindexed assets |
| Tokenizer pre-tokenization | Not specified in detail | Naive whitespace split (not full CLIP regex pre-tokenizer) |

Real dependencies (`pubspec.yaml`):
- `flutter_onnxruntime` — runs the two ONNX sessions
- `libsql_dart` — embedded libSQL client with vector index support
- `photo_manager` / `photo_manager_image_provider` — gallery access, thumbnails, favorite/delete/save
- `dio` — model file download with progress callbacks
- `path_provider` — resolves app documents directory for models + DB file
- `image` — pure-Dart image decode/crop/resize for preprocessing
- `share_plus`, `url_launcher` — share sheet / "open in gallery"
- `shared_preferences` — declared but **not currently used** anywhere in `lib/`

No test files exist (`test/` directory is absent despite `flutter_test` being a dev dependency and CLAUDE.md documenting a `flutter test` workflow).

## 3. App flow / screen graph

```
SplashScreen (lib/screens/splash_screen.dart)
  ├─ checks for model files in app documents dir
  │   ├─ missing  → DownloadScreen
  │   └─ present  → loads ModelService + TokenizerService + DatabaseService
  │                  ├─ DB has images → SearchScreen
  │                  └─ DB empty      → IndexingScreen
  │
DownloadScreen (download_screen.dart)
  └─ downloads image_encoder.onnx + text_encoder.onnx via Dio → back to SplashScreen
  │
IndexingScreen (indexing_screen.dart)
  └─ requests PhotoManager permission → IndexingService.indexAll() → SplashScreen
  │
SearchScreen (search_screen.dart)
  ├─ search bar → TokenizerService.encode → ModelService.encodeText → DatabaseService.searchSimilar
  ├─ paginated result grid (loads AssetEntity objects kSearchPageSize at a time)
  ├─ badge showing unindexed photo count → pushes IndexingScreen
  └─ tap a result → PhotoDetailScreen
  │
PhotoDetailScreen (photo_detail_screen.dart)
  ├─ full image view (AssetEntityImage, isOriginal: true)
  ├─ action bar: share / save-a-copy / open-in-gallery / favorite / more (info, delete)
  └─ "Related" strip: DatabaseService.searchSimilarToAsset (image-to-image k-NN)
```

Every screen navigation is a direct `Navigator.push`/`pushReplacement` call — there is no named-route table or router package.

## 4. Services (`lib/services/`)

All four services are hand-rolled singletons using the `factory` constructor + static instance pattern (no DI framework, no Riverpod providers).

### 4.1 `DatabaseService`
- Wraps a single `LibsqlClient` opened at `<app docs dir>/sims.db`.
- `_migrateSchema()` is a crude migration: it checks whether `idx_vec` exists; if not, it **drops and recreates** the `images` table from scratch. This means any schema change requires bumping to a new index name or all existing embeddings are silently wiped on next launch — there is no versioned migration path.
- Schema: `images(id TEXT PK, asset_id TEXT, embedding F32_BLOB(512))` with a secondary btree index on `asset_id` and a vector index (`libsql_vector_idx`) on `embedding`.
- `id` and `asset_id` are always inserted as the same value (`insertImage(asset.id, asset.id, ...)` in `IndexingService`) — the column split appears to be dead/unused design residue.
- Search methods (`searchSimilar`, `searchSimilarToAsset`) use libSQL's `vector_top_k` table function joined back to `images` by `rowid`.
- Embeddings are serialized to SQL as literal `"[v1,v2,...]"` strings interpolated into the query text via `vector32(?)` — bound as a parameter, not string-concatenated into SQL, so this is not directly SQL-injectable, but note the embedding list itself is never validated for length/NaN before being joined.

### 4.2 `ModelService`
- Wraps `flutter_onnxruntime`'s `OnnxRuntime`, holding one `OrtSession` for the image encoder and one for the text encoder.
- `encodeImage`: builds a `[1, 3, 256, 256]` float tensor, runs the image session, returns the flattened first output.
- `encodeText`: builds `[1, 77]` int64 tensors for input ids, runs the text session. Contains a workaround: if the runtime's ArgMax node isn't supported and the model returns the full `[1, 77, 512]` sequence output instead of the pooled `[1, 512]` embedding, the code manually finds the EOS token (`id 49407`) in `inputIds` and slices out its 512-dim embedding. This is a fragile heuristic tied to a specific CLIP tokenizer's special-token ids and to `kEmbeddingDim`/`kMaxTokenLength` staying in sync with the exported model.
- Note: `encodeText` builds the attention-mask tensor's arguments but the mask is never actually passed to the session (`_textEncoder!.run({'text_input': idsTensor})` — no `attention_mask` key). If the exported ONNX graph expects an attention mask input, it's silently not supplied.

### 4.3 `TokenizerService`
- Loads `assets/tokenizer/tokenizer.json` (HuggingFace tokenizer format) and manually implements CLIP's byte-level BPE: byte→unicode mapping (`_buildByteEncoder`, the standard GPT-2/CLIP trick) + rank-ordered pair merging (`_bpe`).
- Pre-tokenization is a plain `text.split(RegExp(r'\s+'))` rather than CLIP's actual regex pre-tokenizer (which also splits contractions, punctuation, etc.). For short, simple search queries this is usually fine but it will diverge from the reference tokenizer on punctuation-heavy input.
- Truncates/pads to `kMaxTokenLength` (77) with BOS (49406) / EOS (49407) / PAD (0), also producing an attention mask (see 4.2 note that the mask isn't actually forwarded to ONNX).

### 4.4 `IndexingService`
- `getAllAssets()`: paginates through every `AssetPathList` from `photo_manager` in batches of 100, dedupes by id.
- `countUnindexed()`: diffs all device assets against `DatabaseService.getIndexedAssetIds()` — an O(n) full-table id fetch every time it's called (including every time `SearchScreen` mounts and after returning from `IndexingScreen`).
- `indexAll()`: guarded by an in-memory `_running` flag (prevents concurrent runs, but is not persisted — killing the app mid-index leaves no resumption state beyond "whatever's already in the DB won't be re-processed"). For each pending asset: fetch a 256×256 thumbnail (not the original), preprocess, run through `ModelService.encodeImage`, insert. Per-image failures are caught and logged, not surfaced to the user, and don't stop the batch.
- All of this runs synchronously on the UI isolate — there is no isolate/compute offload, so indexing a large library will visibly block the UI thread's frame budget during preprocessing/inference (the progress bar UI still updates because `setState` is called between awaits, but heavy CPU work like `img.decodeImage`/BPE-free tensor packing happens inline).

## 5. Utilities (`lib/utils/`)

- **`constants.dart`**: all magic numbers/URLs live here — model download URLs (hardcoded to a specific GitHub repo/release tag `Chandan-CV/sims v0.0.1`), filenames, `kEmbeddingDim=512`, `kMaxTokenLength=77`, `kImageSize=256`, `kSearchTopK=200`, `kSearchPageSize=50`, and CLIP/MobileCLIP normalization mean/std.
- **`image_preprocessor.dart`**: center-crop to square → resize to 256×256 (linear interpolation) → normalize to `[0,1]` and pack into CHW `Float32List`. **Note:** this normalizes to `0..1` only — the `kImageMean`/`kImageStd` constants defined in `constants.dart` are declared but never applied here. If the exported ONNX image encoder expects CLIP-standard mean/std normalization, this is a correctness bug (embeddings would be off-distribution from what the model was trained/exported to expect, unless the ONNX graph itself contains the normalization step).

## 6. Entry point

`lib/main.dart` is minimal: a `MaterialApp` themed with a `deepPurple` seed color, `home: SplashScreen()`. All actual bootstrapping (model loading, DB open, tokenizer init) happens inside `SplashScreen`, not `main()`.

## 7. Known gaps / quality notes (for review & prioritization)

1. **No isolate/compute offloading** — every ONNX inference call and image decode runs on the UI thread. This is the single biggest deviation from the original plan and the most likely source of jank during indexing.
2. **Image preprocessing likely skips mean/std normalization** (`kImageMean`/`kImageStd` unused) — worth verifying against how the ONNX model was exported before trusting search quality.
3. **Text encoder attention mask is computed but never passed to the ONNX session** — dead code, or a missing wiring bug depending on what the model graph expects.
4. **Schema migration drops all data on schema change** — acceptable for a solo/pre-release project, unacceptable once real user data needs to survive an app update.
5. **No persisted indexing progress/resume state** — an app kill mid-index just leaves partial results; the user has to re-open the Indexing screen to pick up remaining assets (which does work, since indexing is idempotent per-asset).
6. **`countUnindexed()` does a full asset scan + full DB id fetch** on every `SearchScreen` mount — fine at current photo-library scales, will not scale to tens of thousands of photos without pagination/streaming.
7. **No automated tests** despite `flutter_test` being present as a dependency and referenced in `CLAUDE.md`.
8. **`shared_preferences` dependency is unused.**
9. **Model URLs are hardcoded to a personal GitHub release** — fine for a personal project, but a hard-coupling that should move to config if this is ever shared/forked.
10. **Simple whitespace tokenizer pre-split** rather than CLIP's true regex pre-tokenizer — likely negligible for short search phrases, worth flagging if search quality on punctuation-heavy queries is ever reported as poor.

## 8. Quick-reference file index (for LLM context loading)

| File | Responsibility |
|---|---|
| `lib/main.dart` | App root, theme, initial route |
| `lib/screens/splash_screen.dart` | Boot sequence: check models → load services → route to Download/Indexing/Search |
| `lib/screens/download_screen.dart` | One-time ONNX model download (Dio + progress bars) |
| `lib/screens/indexing_screen.dart` | Permission request + drives `IndexingService.indexAll` with a progress UI |
| `lib/screens/search_screen.dart` | Search bar, paginated result grid, unindexed-count badge |
| `lib/screens/photo_detail_screen.dart` | Full-screen photo view, share/save/open/favorite/delete, "related" image-to-image search strip |
| `lib/services/database_service.dart` | libSQL connection, schema/migration, insert + vector search queries |
| `lib/services/model_service.dart` | ONNX Runtime session management, image/text encoding |
| `lib/services/tokenizer_service.dart` | CLIP byte-level BPE tokenizer (loads `tokenizer.json`) |
| `lib/services/indexing_service.dart` | Enumerates device photos, diffs against DB, drives indexing loop |
| `lib/utils/constants.dart` | Global constants: URLs, filenames, dims, search params, normalization stats |
| `lib/utils/image_preprocessor.dart` | Decode/crop/resize/normalize an image into a model input tensor |
| `assets/tokenizer/tokenizer.json` | HuggingFace-format CLIP tokenizer vocab + merges |
