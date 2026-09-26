import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/database_service.dart';
import '../utils/constants.dart';

class PhotoDetailScreen extends StatefulWidget {
  const PhotoDetailScreen({super.key, required this.asset});

  final AssetEntity asset;

  @override
  State<PhotoDetailScreen> createState() => _PhotoDetailScreenState();
}

class _PhotoDetailScreenState extends State<PhotoDetailScreen> {
  List<AssetEntity> _related = [];
  bool _loadingRelated = true;
  bool _isFavorite = false;

  @override
  void initState() {
    super.initState();
    _loadRelated();
    _loadFavoriteState();
  }

  Future<void> _loadRelated() async {
    try {
      final ids = await DatabaseService()
          .searchSimilarToAsset(widget.asset.id, kSearchTopK);
      final assets = <AssetEntity>[];
      for (final id in ids.take(kSearchPageSize)) {
        final asset = await AssetEntity.fromId(id);
        if (asset != null) assets.add(asset);
      }
      if (mounted) setState(() => _related = assets);
    } finally {
      if (mounted) setState(() => _loadingRelated = false);
    }
  }

  Future<void> _loadFavoriteState() async {
    if (mounted) setState(() => _isFavorite = widget.asset.isFavorite);
  }

  Future<void> _share() async {
    final file = await widget.asset.file;
    if (file == null) return;
    await Share.shareXFiles([XFile(file.path)]);
  }

  Future<void> _save() async {
    final data = await widget.asset.originBytes;
    if (data == null) return;
    final title = widget.asset.title ?? 'sims_photo';
    await PhotoManager.editor.saveImage(data, filename: title);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved a copy to gallery')),
      );
    }
  }

  Future<void> _openInGallery() async {
    // A raw file:// path can't be handed to another app's Intent — Android
    // has blocked that since API 24 (FileUriExposedException). MediaStore's
    // own content:// URI is what other apps are allowed to receive.
    final url = await widget.asset.getMediaUrl();
    if (url == null) return;
    final uri = Uri.parse(url);
    debugPrint('Opening in gallery: $uri');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open in gallery')),
        );
      }
    }
  }

  Future<void> _toggleFavorite() async {
    final nowFav = !_isFavorite;
    try {
      if (Theme.of(context).platform == TargetPlatform.iOS ||
          Theme.of(context).platform == TargetPlatform.macOS) {
        await PhotoManager.editor.darwin
            .favoriteAsset(entity: widget.asset, favorite: nowFav);
      } else {
        await PhotoManager.editor.android
            .favoriteAsset(entity: widget.asset, favorite: nowFav);
      }
      if (mounted) {
        setState(() => _isFavorite = nowFav);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(nowFav ? 'Added to favorites' : 'Removed from favorites'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update favorite: $e')),
        );
      }
    }
  }

  void _showMore() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MoreOption(
              icon: Icons.info_outline,
              label: 'Info',
              onTap: () {
                Navigator.pop(context);
                _showInfo();
              },
            ),
            _MoreOption(
              icon: Icons.delete_outline,
              label: 'Delete',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                _confirmDelete();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showInfo() {
    final asset = widget.asset;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Photo info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (asset.title != null) _InfoRow('Name', asset.title!),
            _InfoRow('Size', '${asset.width} × ${asset.height}'),
            _InfoRow('Type', asset.mimeType ?? '—'),
            _InfoRow('Date', asset.createDateTime.toString().split('.').first),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete photo?'),
        content: const Text('This will permanently delete the photo from your device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await PhotoManager.editor.deleteWithIds([widget.asset.id]);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.asset.title ?? '',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 5.0,
              panEnabled: true,
              scaleEnabled: true,
              child: AssetEntityImage(
                widget.asset,
                isOriginal: true,
                fit: BoxFit.contain,
              ),
            ),
          ),
          _buildActionBar(),
          _buildRelatedSection(),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    return Container(
      color: const Color(0xFF1C1C1E),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ActionButton(
            icon: Icons.share_outlined,
            label: 'Share',
            onTap: _share,
          ),
          _ActionButton(
            icon: Icons.save_alt_outlined,
            label: 'Save',
            onTap: _save,
          ),
          _ActionButton(
            icon: Icons.open_in_new_outlined,
            label: 'Gallery',
            onTap: _openInGallery,
          ),
          _ActionButton(
            icon: _isFavorite ? Icons.favorite : Icons.favorite_border,
            label: 'Favorite',
            color: _isFavorite ? Colors.red : Colors.white,
            onTap: _toggleFavorite,
          ),
          _ActionButton(
            icon: Icons.more_horiz,
            label: 'More',
            onTap: _showMore,
          ),
        ],
      ),
    );
  }

  Widget _buildRelatedSection() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Related',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: Colors.white70),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            child: _loadingRelated
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white54))
                : _related.isEmpty
                    ? const Center(
                        child: Text('No related photos',
                            style: TextStyle(color: Colors.white54)))
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: _related.length,
                        itemBuilder: (_, index) {
                          final asset = _related[index];
                          return GestureDetector(
                            onTap: () =>
                                Navigator.of(context).pushReplacement(
                              MaterialPageRoute(
                                builder: (_) =>
                                    PhotoDetailScreen(asset: asset),
                              ),
                            ),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: AssetEntityImage(
                                  asset,
                                  isOriginal: false,
                                  thumbnailSize:
                                      const ThumbnailSize.square(200),
                                  fit: BoxFit.cover,
                                  width: 100,
                                  height: 100,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(color: color.withAlpha(200), fontSize: 11)),
        ],
      ),
    );
  }
}

class _MoreOption extends StatelessWidget {
  const _MoreOption({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
