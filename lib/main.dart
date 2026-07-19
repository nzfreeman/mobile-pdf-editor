import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'screens/home_screen.dart';
import 'services/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize();
  await AppSettings.initialize();
  runApp(const PdfEditorApp());
}

class PdfEditorApp extends StatelessWidget {
  const PdfEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.themeMode,
      builder: (_, themeMode, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Mobile PDF Editor',
        themeMode: themeMode,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF174A5B)),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF3F5F6),
        ),
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4CC2D8),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
