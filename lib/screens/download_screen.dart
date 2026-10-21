import 'dart:io';

import 'package:crypto/crypto.dart';
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

  Future<void> _verifyChecksum(File file, String expectedSha256) async {
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString().toLowerCase() != expectedSha256.toLowerCase()) {
      throw Exception(
          'Checksum mismatch for ${file.path}: expected $expectedSha256 but got $digest');
    }
  }

  Future<void> _startDownload() async {
    setState(() {
      _phase = _Phase.downloading;
      _error = null;
      _imageProgress = 0;
      _textProgress = 0;
    });

    final dir = await getApplicationDocumentsDirectory();
    final imgPath = '${dir.path}/$kImageEncoderFilename';
    final txtPath = '${dir.path}/$kTextEncoderFilename';
    final imgTmpPath = '$imgPath.tmp';
    final txtTmpPath = '$txtPath.tmp';

    try {
      final dio = Dio();

      debugPrint('[SIMS] downloading img → $imgTmpPath');
      await dio.download(
        kImageEncoderUrl,
        imgTmpPath,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _imageProgress = received / total);
          }
        },
      );
      debugPrint('[SIMS] img download complete');

      debugPrint('[SIMS] downloading txt → $txtTmpPath');
      await dio.download(
        kTextEncoderUrl,
        txtTmpPath,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _textProgress = received / total);
          }
        },
      );
      debugPrint('[SIMS] txt download complete');

      if (mounted) {
        setState(() => _phase = _Phase.verifying);
      }

      debugPrint('[SIMS] verifying image encoder checksum…');
      await _verifyChecksum(File(imgTmpPath), kImageEncoderSha256);

      debugPrint('[SIMS] verifying text encoder checksum…');
      await _verifyChecksum(File(txtTmpPath), kTextEncoderSha256);

      // Atomically move verified models into final paths.
      final imgFinal = File(imgPath);
      if (imgFinal.existsSync()) imgFinal.deleteSync();
      await File(imgTmpPath).rename(imgPath);

      final txtFinal = File(txtPath);
      if (txtFinal.existsSync()) txtFinal.deleteSync();
      await File(txtTmpPath).rename(txtPath);

      debugPrint('[SIMS] both models verified and ready');

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
      debugPrint('[SIMS] verification/download error: $e\n$st');
      if (mounted) {
        setState(() {
          _phase = _Phase.idle;
          _error = 'Error: $e';
        });
      }
    } finally {
      // Clean up incomplete temporary files if an error occurred.
      final imgTmp = File(imgTmpPath);
      if (imgTmp.existsSync()) {
        try {
          imgTmp.deleteSync();
        } catch (_) {}
      }
      final txtTmp = File(txtTmpPath);
      if (txtTmp.existsSync()) {
        try {
          txtTmp.deleteSync();
        } catch (_) {}
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
                'To get started, download the on-device AI models ($kModelDownloadSizeLabel).',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const Spacer(),
              if (_phase == _Phase.verifying) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                Text('Verifying model integrity…',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
              ] else if (_phase == _Phase.downloading) ...[
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

enum _Phase { idle, downloading, verifying }
