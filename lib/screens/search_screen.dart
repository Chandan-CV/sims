import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../services/database_service.dart';
import '../services/indexing_service.dart';
import '../services/model_service.dart';
import '../services/tokenizer_service.dart';
import '../utils/constants.dart';
import 'favorites_screen.dart';
import 'indexing_screen.dart';
import 'photo_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  List<String> _resultIds = [];
  List<AssetEntity> _results = [];
  bool _searching = false;
  bool _loadingMore = false;
  int _unindexedCount = 0;

  @override
  void initState() {
    super.initState();
    _checkUnindexed();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 400 &&
        !_loadingMore &&
        _results.length < _resultIds.length) {
      _loadNextPage();
    }
  }

  Future<void> _loadNextPage() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);

    final start = _results.length;
    final end = (start + kSearchPageSize).clamp(0, _resultIds.length);
    final batch = <AssetEntity>[];
    final missing = <String>{};
    for (final id in _resultIds.sublist(start, end)) {
      final asset = await AssetEntity.fromId(id);
      if (asset != null) {
        batch.add(asset);
      } else {
        missing.add(id);
      }
    }

    // A hit that no longer resolves was deleted from the device: drop its
    // row now instead of scanning the whole library for deletions. Only
    // trust that under full access — with limited access (iOS) fromId also
    // returns null for photos that exist but weren't shared with the app.
    if (missing.isNotEmpty) {
      final state = await PhotoManager.getPermissionState(
          requestOption: const PermissionRequestOption());
      if (state == PermissionState.authorized) {
        await DatabaseService().deleteAssetIds(missing);
        _resultIds = [
          for (final id in _resultIds)
            if (!missing.contains(id)) id,
        ];
      }
    }

    if (mounted) {
      setState(() {
        _results.addAll(batch);
        _loadingMore = false;
      });
    }
  }

  Future<void> _checkUnindexed() async {
    final count = await IndexingService().countUnindexed();
    if (mounted) setState(() => _unindexedCount = count);
  }

  Future<void> _search(String query) async {
    debugPrint('[SIMS] Searching for: $query');
    query = query.trim();
    if (query.isEmpty) return;
    _focusNode.unfocus();

    setState(() {
      _searching = true;
      _resultIds = [];
      _results = [];
    });

    try {
      final tokenizer = TokenizerService();
      final (inputIds, attentionMask) = tokenizer.tokenize(query);
      final embedding = await ModelService().encodeText(inputIds, attentionMask);

      _resultIds = await DatabaseService().searchSimilar(embedding, kSearchTopK);
      await _loadNextPage();
    } catch (e) {
      debugPrint('[SIMS] Search failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SIMS'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SearchBar(
              controller: _controller,
              focusNode: _focusNode,
              hintText: 'Search your photos…',
              leading: const Icon(Icons.search),
              trailing: [
                if (_searching)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
              onSubmitted: _search,
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Favorites',
            icon: const Icon(Icons.favorite_outline),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const FavoritesScreen(),
            )),
          ),
          IconButton(
            tooltip: _unindexedCount > 0
                ? '$_unindexedCount photos not yet indexed'
                : 'Index photos',
            icon: Badge(
              isLabelVisible: _unindexedCount > 0,
              label: Text('$_unindexedCount'),
              child: const Icon(Icons.photo_library_outlined),
            ),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => const IndexingScreen()))
                .then((_) => _checkUnindexed()),
          ),
        ],
      ),
      body: _resultIds.isEmpty && !_searching
          ? _buildEmpty()
          : _buildGrid(),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_search,
              size: 72, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            'Search your photos with natural language',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '"sunset at the beach", "birthday cake", "my dog"',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                  fontStyle: FontStyle.italic,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _results.length + (_loadingMore ? 3 : 0),
      itemBuilder: (_, index) {
        if (index >= _results.length) {
          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
          );
        }
        final asset = _results[index];
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PhotoDetailScreen(asset: asset),
          )),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AssetEntityImage(
              asset,
              isOriginal: false,
              thumbnailSize: const ThumbnailSize.square(300),
              fit: BoxFit.cover,
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
