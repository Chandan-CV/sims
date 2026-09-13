import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/constants.dart';
import 'home_screen.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  _Phase _phase = _Phase.idle;
  double _imageProgress = 0;
  double _textProgress = 0;
  String? _error;

  Future<void> _startDownload() async {
    setState(() {
      _phase = _Phase.downloading;
      _error = null;
      _imageProgress = 0;
      _textProgress = 0;
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final dio = Dio();

      final imgPath = '${dir.path}/$kImageEncoderFilename';
      final txtPath = '${dir.path}/$kTextEncoderFilename';

      debugPrint('[SIMS] downloading img → $imgPath');
      await dio.download(
        kImageEncoderUrl,
        imgPath,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _imageProgress = received / total);
          }
        },
      );
      debugPrint('[SIMS] img done — exists=${File(imgPath).existsSync()}  size=${File(imgPath).existsSync() ? File(imgPath).lengthSync() : 0} bytes');

      debugPrint('[SIMS] downloading txt → $txtPath');
      await dio.download(
        kTextEncoderUrl,
        txtPath,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _textProgress = received / total);
          }
        },
      );
      debugPrint('[SIMS] txt done — exists=${File(txtPath).existsSync()}  size=${File(txtPath).existsSync() ? File(txtPath).lengthSync() : 0} bytes');

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } on DioException catch (e) {
      debugPrint('[SIMS] DioException: ${e.type} — ${e.message}');
      if (mounted) {
        setState(() {
          _phase = _Phase.idle;
          _error = 'Download failed: ${e.message}';
        });
      }
    } catch (e, st) {
      debugPrint('[SIMS] unexpected error: $e\n$st');
      if (mounted) {
        setState(() {
          _phase = _Phase.idle;
          _error = 'Error: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Text('SIMS',
                  style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Text(
                'To get started, download the on-device AI models (~100 MB).',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const Spacer(),
              if (_phase == _Phase.downloading) ...[
                _ModelProgress(
                    label: 'Image encoder', progress: _imageProgress),
                const SizedBox(height: 16),
                _ModelProgress(
                    label: 'Text encoder', progress: _textProgress),
              ] else ...[
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center),
                  ),
                FilledButton(
                  onPressed: _startDownload,
                  child: const Text('Download models'),
                ),
              ],
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelProgress extends StatelessWidget {
  const _ModelProgress({required this.label, required this.progress});

  final String label;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text('${(progress * 100).toStringAsFixed(0)}%'),
          ],
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: progress),
      ],
    );
  }
}

enum _Phase { idle, downloading }
