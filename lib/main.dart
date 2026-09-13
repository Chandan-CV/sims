import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/background_sync_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Registers the nightly background sync job with the OS
  // scheduler. Cheap and safe to call unconditionally on every launch.
  BackgroundSyncService().initializeScheduler();
  runApp(const SimsApp());
}

class SimsApp extends StatelessWidget {
  const SimsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SIMS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const _AppLifecycleSync(child: HomeScreen()),
    );
  }
}

/// Kicks off an in-process background sync whenever the app returns to the
/// foreground, so indexing keeps up with the library without the user
/// having to babysit the Indexing screen. No-ops quietly if models/DB
/// aren't ready yet (e.g. still on the download/onboarding screens).
class _AppLifecycleSync extends StatefulWidget {
  const _AppLifecycleSync({required this.child});

  final Widget child;

  @override
  State<_AppLifecycleSync> createState() => _AppLifecycleSyncState();
}

class _AppLifecycleSyncState extends State<_AppLifecycleSync>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      BackgroundSyncService().runSync();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
