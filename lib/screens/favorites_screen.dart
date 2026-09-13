import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../utils/constants.dart';
import 'photo_detail_screen.dart';

/// Shows every photo currently marked favorite on the device (the same
/// `AssetEntity.isFavorite` flag [PhotoDetailScreen] toggles), independent
/// of whatever the OS-level Gallery app does or doesn't do with it.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  AssetPathEntity? _favoritesPath;
  final List<AssetEntity> _results = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 400 &&
        !_loadingMore &&
        _hasMore) {
      _loadNextPage();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: CustomFilter.sql(
        where: '${CustomColumns.base.isFavorite} = 1',
        orderBy: [OrderByItem.desc(CustomColumns.base.createDate)],
      ),
    );
    _favoritesPath = paths.isNotEmpty ? paths.first : null;
    _results.clear();
    _hasMore = true;
    if (mounted) setState(() => _loading = false);
    await _loadNextPage();
  }

  Future<void> _loadNextPage() async {
    final path = _favoritesPath;
    if (path == null || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);

    final start = _results.length;
    final batch = await path.getAssetListRange(
      start: start,
      end: start + kSearchPageSize,
    );

    if (mounted) {
      setState(() {
        _results.addAll(batch);
        _hasMore = batch.length == kSearchPageSize;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Favorites')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? _buildEmpty()
              : _buildGrid(),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.favorite_border,
              size: 72, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            'No favorites yet',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Tap the heart on a photo to add it here',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
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
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PhotoDetailScreen(asset: asset),
            ));
            // Coming back after possibly un-favoriting from the detail
            // screen — refresh so the grid doesn't show stale entries.
            _load();
          },
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
}
