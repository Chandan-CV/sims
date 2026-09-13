import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/database_service.dart';
import '../services/model_service.dart';
import '../services/tokenizer_service.dart';
import '../utils/constants.dart';
import 'download_screen.dart';
import 'indexing_screen.dart';
import 'search_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _status = 'Starting…';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      debugPrint('[SIMS] Checking models…');
      _setStatus('Checking models…');
      final dir = await getApplicationDocumentsDirectory();
      final imgPath = '${dir.path}/$kImageEncoderFilename';
      final txtPath = '${dir.path}/$kTextEncoderFilename';

      final imgExists = File(imgPath).existsSync();
      final txtExists = File(txtPath).existsSync();

      debugPrint('[SIMS] docs dir   : ${dir.path}');
      debugPrint('[SIMS] img path   : $imgPath  exists=$imgExists');
      debugPrint('[SIMS] txt path   : $txtPath  exists=$txtExists');

      final modelsExist = imgExists && txtExists;

      if (!modelsExist) {
        _navigate(const DownloadScreen());
        return;
      }

      await _loadEverything(imgPath, txtPath);
    } catch (e) {
      _setStatus('Error: $e');
    }
  }

  Future<void> _loadEverything(String imgPath, String txtPath) async {
    if (!ModelService().isLoaded) {
      _setStatus('Loading models…');
      await ModelService().loadModels(imgPath, txtPath);
    }

    _setStatus('Loading tokenizer…');
    await TokenizerService().init();

    _setStatus('Opening database…');
    await DatabaseService().init();

    final (_, indexedCount) = await DatabaseService().getIndexStats();
    if (!mounted) return;

    if (indexedCount > 0) {
      _navigate(const SearchScreen());
    } else {
      _navigate(const IndexingScreen());
    }
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _navigate(Widget screen) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('SIMS',
                style:
                    TextStyle(fontSize: 36, fontWeight: FontWeight.bold)),
            const SizedBox(height: 32),
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(_status,
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
