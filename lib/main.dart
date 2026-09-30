import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/background_index_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Registers the WorkManager plugin for the "Run in background" indexing
  // hand-off (see BackgroundIndexService). This does not schedule or start
  // anything on its own — cheap and safe to call unconditionally.
  await BackgroundIndexService().initialize();
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
      home: const HomeScreen(),
    );
  }
}
