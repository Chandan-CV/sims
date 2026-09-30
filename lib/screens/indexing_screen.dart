import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/background_index_service.dart';
import '../services/database_service.dart';
import '../services/indexing_service.dart';
import '../services/notification_service.dart';
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
  bool _handingOff = false;
  Timer? _bgPoll;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  @override
  void dispose() {
    _bgPoll?.cancel();
    super.dispose();
  }

  Future<void> _loadStats() async {
    // Coming back to this screen while a handed-off run is still going: show
    // that run's progress instead of re-offering to index from scratch.
    if (await BackgroundIndexService().isRunning()) {
      final (total, indexed) = await IndexingService().getIndexStats();
      if (!mounted) return;
      setState(() {
        _total = total;
        _indexed = indexed;
        _phase = _Phase.background;
      });
      _startBackgroundPolling();
      return;
    }

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

  /// Hands the currently-running indexing pass off to the OS: stops the
  /// in-app loop, waits for it to actually release its run-lock (only one
  /// run is allowed at a time), then schedules a background task that
  /// continues where it left off — as an Android foreground service with a
  /// progress notification, so it keeps going even if you leave the app.
  Future<void> _runInBackground() async {
    if (_handingOff) return;
    setState(() => _handingOff = true);

    // Must happen here, in the foreground, while an Activity exists to show
    // the system permission dialog from — requesting it from inside the
    // headless background task itself silently fails (no Activity there).
    await NotificationService().requestPermission();

    _stop = true;
    while (IndexingService().isRunning) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await BackgroundIndexService().start();
    _goToSearch();
  }

  /// Polls the state of the handed-off run. Counts come straight from the
  /// database rather than any cross-isolate progress payload: both isolates
  /// open the same SQLite file, so every embedding the background task
  /// commits is immediately visible here. [BackgroundIndexService.isRunning]
  /// is only used to answer "is it still alive".
  void _startBackgroundPolling() {
    _bgPoll?.cancel();
    _bgPoll = Timer.periodic(const Duration(seconds: 1), (_) async {
      final running = await BackgroundIndexService().isRunning();
      final (total, indexed) = await IndexingService().getIndexStats();
      if (!mounted) return;

      if (!running) {
        _bgPoll?.cancel();
        setState(() {
          _indexed = indexed;
          _total = total;
          _phase = _Phase.done;
        });
        return;
      }
      setState(() {
        _indexed = indexed;
        _total = total;
      });
    });
  }

  Future<void> _cancelBackground() async {
    _bgPoll?.cancel();
    await BackgroundIndexService().cancel();
    if (!mounted) return;
    setState(() => _phase = _Phase.loading);
    await _loadStats();
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
        // If we're handing off to the background, _runInBackground drives
        // navigation itself once the background task is actually scheduled.
        if (_stop) {
          if (!_handingOff) _goToSearch();
        } else {
          setState(() => _phase = _Phase.done);
        }
      }
    } catch (e) {
      if (mounted && !_handingOff) {
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
            _Phase.background => _buildBackgroundStatus(),
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
        // Android only: no true foreground-service equivalent exists on iOS,
        // so this hand-off isn't offered there.
        if (Platform.isAndroid) ...[
          TextButton.icon(
            onPressed: _handingOff ? null : _runInBackground,
            icon: _handingOff
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.notifications_active_outlined),
            label: Text(_handingOff ? 'Handing off…' : 'Run in background'),
          ),
          Text(
            'Keeps indexing with a progress notification, even if you leave the app.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          const SizedBox(height: 8),
        ],
        TextButton(
          onPressed: _handingOff ? null : () => setState(() => _stop = true),
          child: const Text('Stop & search with indexed photos'),
        ),
      ],
    );
  }

  /// Shown when the user returns to this screen while a handed-off run is
  /// still going in the background. Read-only status plus a way out — the
  /// run itself belongs to the OS now, so the only thing to do here is watch
  /// it, leave it be, or stop it.
  Widget _buildBackgroundStatus() {
    final total = _total;
    final indexed = _indexed;
    final remaining = total - indexed;
    final theme = Theme.of(context);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.sync, size: 72, color: theme.colorScheme.primary),
        const SizedBox(height: 24),
        Text(
          'Indexing in the background',
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          total > 0
              ? '$indexed of $total photos · $remaining remaining'
              : 'Preparing…',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 32),
        LinearProgressIndicator(value: total > 0 ? indexed / total : null),
        const SizedBox(height: 24),
        Text(
          'This keeps running even if you leave the app. You can search '
          'the photos already indexed while it finishes.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 40),
        FilledButton(
          onPressed: _goToSearch,
          child: const Text('Search indexed photos'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _cancelBackground,
          child: const Text('Stop background indexing'),
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

enum _Phase { loading, discovering, prompt, indexing, background, done }
