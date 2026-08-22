import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/generated/app_localizations.dart';
import 'models/app_locale.dart';
import 'screens/home_screen.dart';
import 'services/sfx_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore custom channel-event sounds persisted in the private documents
  // directory (built-in samples remain active for kinds without a file).
  await SfxService.init();
  runApp(const ProviderScope(child: TeamSpeakApp()));
}

class TeamSpeakApp extends ConsumerWidget {
  const TeamSpeakApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    return MaterialApp(
      title: 'TeamSpeak',
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F23),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF16213E),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardColor: const Color(0xFF1A1A2E),
        dividerColor: const Color(0xFF2A2A4A),
      ),
      home: const HomeScreen(),
    );
  }
}
