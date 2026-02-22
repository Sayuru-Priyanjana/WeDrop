import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'screens/home_screen.dart';
import 'services/theme_provider.dart';

void main() {
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
      child: const WeDropApp(),
    ),
  );
}

class WeDropApp extends StatelessWidget {
  const WeDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          title: 'WeDrop',
          debugShowCheckedModeBanner: false,

          /* ------------- LIGHT UI PACK (Vibrant Azure & Clean White) ------------- */
          theme: ThemeData(
            brightness: Brightness.light,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0284C7), // Azure Blue
              brightness: Brightness.light,
              primary: const Color(0xFF0284C7),
              secondary: const Color(0xFF0EA5E9),
              surface: const Color(0xFFFFFFFF),
              surfaceTint: Colors.white,
            ),
            scaffoldBackgroundColor: const Color(0xFFF8FAFC), // Slate 50
            useMaterial3: true,
            appBarTheme: const AppBarTheme(
              centerTitle: true,
              elevation: 0,
              backgroundColor: Colors.transparent,
              foregroundColor: Color(0xFF0F172A), // Slate 900
            ),
            cardTheme: CardTheme(
              elevation: 8,
              shadowColor: const Color(
                0xFF94A3B8,
              ).withValues(alpha: 0.2), // Slate 400
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            listTileTheme: const ListTileThemeData(
              iconColor: Color(0xFF0284C7),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                elevation: 4,
                shadowColor: const Color(0xFF0284C7).withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            floatingActionButtonTheme: const FloatingActionButtonThemeData(
              backgroundColor: Color(0xFF0284C7),
              foregroundColor: Colors.white,
            ),
          ),

          /* ------------- DARK UI PACK (Midnight & Cyber Purple) ------------- */
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFA855F7), // Cyber Purple
              brightness: Brightness.dark,
              primary: const Color(0xFFA855F7),
              secondary: const Color(0xFFD946EF), // Fuchsia
              surface: const Color(0xFF1E293B), // Slate 800
              surfaceTint: const Color(0xFF1E293B),
            ),
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(
              0xFF0F172A,
            ), // Midnight Slate 900
            appBarTheme: const AppBarTheme(
              centerTitle: true,
              elevation: 0,
              backgroundColor: Colors.transparent,
              foregroundColor: Color(0xFFF8FAFC), // Slate 50
            ),
            cardTheme: CardTheme(
              elevation: 12,
              shadowColor: Colors.black.withValues(alpha: 0.5),
              color: const Color(0xFF1E293B), // Slate 800
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: const Color(0xFFA855F7).withValues(alpha: 0.2),
                  width: 1,
                ), // Glowing edge effect
              ),
            ),
            listTileTheme: const ListTileThemeData(
              iconColor: Color(0xFFA855F7),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFA855F7), // Cyber Purple
                foregroundColor: Colors.white,
                elevation: 8,
                shadowColor: const Color(0xFFA855F7).withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            floatingActionButtonTheme: const FloatingActionButtonThemeData(
              backgroundColor: Color(0xFFA855F7),
              foregroundColor: Colors.white,
            ),
          ),
          themeMode: themeProvider.themeMode,
          home: const HomeScreen(),
        );
      },
    );
  }
}
