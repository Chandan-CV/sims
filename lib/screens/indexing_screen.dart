import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/database_service.dart';
import '../services/indexing_service.dart';
import '../services/photo_diff_service.dart';
import 'home_screen.dart';

class IndexingScreen extends StatefulWidget {
  const IndexingScreen({super.key});

  @override
  State<IndexingScreen> createState() => _IndexingScreenState();
}

class _IndexingScreenState extends State<IndexingScreen> {
  _Phase _phase = _Phase.loading;
  int _indexed = 0;
  int _total = 0;
  int _discoverySeen = 0;
  int _discoveryTotal = 0;
  bool _stop = false;
  String? _error;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final result = await PhotoManager.requestPermissionExtend();
    if (!result.hasAccess) {
      if (mounted) {
        setState(() {
          _phase = _Phase.prompt;
          _error = 'Photo access is required to index your images.';
        });
      }
      return;
    }

    final firstRun = !await DatabaseService().hasDiscoveredAssets();
    if (firstRun) {
      if (mounted) setState(() => _phase = _Phase.discovering);
      await IndexingService().discoverAssets(
        onProgress: (seen, total) {
          if (mounted) {
            setState(() {
              _discoverySeen = seen;
              _discoveryTotal = total;
            });
          }
        },
      );
      // The walk above just registered every asset on the device — nothing
      // left for PhotoDiffService to find, so it only needs a baseline to
      // diff against from here on.
      await PhotoDiffService().markSynced();
    }

    await _refreshStats();
  }

  Future<void> _refreshStats() async {
    final (total, indexed) = await IndexingService().getIndexStats();
    // Publishes to PhotoDiffService().lastDiff — _buildPrompt reads it from
    // there via ValueListenableBuilder rather than holding its own copy.
    await PhotoDiffService().checkForChanges();
    if (mounted) {
      setState(() {
        _total = total;
        _indexed = indexed;
        _phase = _Phase.prompt;
      });
    }
  }

  /// Registers photos added since the last sync as pending rows, so they
  /// show up in "remaining" and get picked up by the next "Index photos"
  /// run. Doesn't index anything itself — sync and index stay separate
  /// steps the user triggers individually.
  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await PhotoDiffService().syncNewPhotos();
      await _refreshStats();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _requestAndIndex() async {
    final result = await PhotoManager.requestPermissionExtend();
    debugPrint('PhotoManager permission result: ${result.hasAccess}, ${result.isAuth}');
    if (!result.hasAccess) {
      await PhotoManager.openSetting();
      if (mounted) {
        setState(
            () => _error = 'Photo access is required to index your images.');
      }
      return;
    }

    setState(() {
      _phase = _Phase.indexing;
      _indexed = 0;
      _total = 0;
      _stop = false;
      _error = null;
    });

    try {
      debugPrint('Starting indexing...');
      await IndexingService().indexAll(
        onProgress: (indexed, total) {
          if (mounted) {
            setState(() {
              _indexed = indexed;
              _total = total;
            });
          }
        },
        shouldStop: () => _stop,
      );

      if (mounted) {
        if (_stop) {
          _goToSearch();
        } else {
          setState(() => _phase = _Phase.done);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.prompt;
          _error = 'Indexing failed: $e';
        });
      }
    }
  }

  void _goToSearch() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: switch (_phase) {
            _Phase.loading => const Center(child: CircularProgressIndicator()),
            _Phase.discovering => _buildDiscovering(),
            _Phase.prompt => _buildPrompt(),
            _Phase.indexing => _buildProgress(),
            _Phase.done => _buildDone(),
          },
        ),
      ),
    );
  }

  Widget _buildDiscovering() {
    final progress =
        _discoveryTotal > 0 ? _discoverySeen / _discoveryTotal : null;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Scanning your photo library…',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '$_discoverySeen of $_discoveryTotal',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 32),
        LinearProgressIndicator(value: progress),
      ],
    );
  }

  Widget _buildPrompt() {
    // Reads PhotoDiffService's shared value rather than a local copy — it
    // may already hold a result from home_screen's own check on launch, so
    // this can render a badge before _refreshStats()'s own check resolves,
    // then update again once it does.
    return ValueListenableBuilder<PhotoDiff?>(
      valueListenable: PhotoDiffService().lastDiff,
      builder: (context, diff, _) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Badge(
                isLabelVisible: diff != null && diff.hasChanges,
                label: Text('${diff?.total ?? 0}'),
                child: const Icon(Icons.photo_library_outlined, size: 80),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Index your photos',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'SIMS will analyse your photos once to enable semantic search. '
              'This is a one-time process and everything stays on your device.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            Text(
              '$_indexed of $_total photos indexed · ${_total - _indexed} remaining',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (diff != null && diff.hasChanges) ...[
              const SizedBox(height: 8),
              Text(
                '${[
                  if (diff.added > 0) '${diff.added} new',
                  if (diff.removed > 0) '${diff.removed} removed',
                ].join(' · ')} since last sync',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _syncing ? null : _syncNow,
                icon: _syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(_syncing ? 'Syncing…' : 'Sync now'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center),
            ],
            const SizedBox(height: 48),
            FilledButton(
              onPressed: _requestAndIndex,
              child: const Text('Index photos'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProgress() {
    final progress = _total > 0 ? _indexed / _total : 0.0;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Indexing photos…',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '$_indexed of $_total',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 32),
        LinearProgressIndicator(value: _total > 0 ? progress : null),
        const SizedBox(height: 40),
        TextButton(
          onPressed: () => setState(() => _stop = true),
          child: const Text('Stop & search with indexed photos'),
        ),
      ],
    );
  }

  Widget _buildDone() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle_outline, size: 80, color: Colors.green),
        const SizedBox(height: 24),
        Text(
          'All $_indexed photos indexed!',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 48),
        FilledButton(
          onPressed: _goToSearch,
          child: const Text('Start searching'),
        ),
      ],
    );
  }
}

enum _Phase { loading, discovering, prompt, indexing, done }
