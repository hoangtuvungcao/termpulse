import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';

enum AppThemePreset {
  dark('Dark'),
  light('Light');

  final String displayName;
  const AppThemePreset(this.displayName);
}

class AppSettingsState {
  final AppLanguage language;
  final AppThemePreset themePreset;
  final double terminalFontSize;

  const AppSettingsState({
    this.language = AppLanguage.vi,
    this.themePreset = AppThemePreset.dark,
    this.terminalFontSize = 13.5,
  });

  AppSettingsState copyWith({
    AppLanguage? language,
    AppThemePreset? themePreset,
    double? terminalFontSize,
  }) {
    return AppSettingsState(
      language: language ?? this.language,
      themePreset: themePreset ?? this.themePreset,
      terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    );
  }
}

class SettingsController extends Notifier<AppSettingsState> {
  String? _prefsPath;

  @override
  AppSettingsState build() => const AppSettingsState();

  Future<void> loadFromDisk() async {
    try {
      final dir = await ForegroundBridge.getAppDataDir();
      final path = '$dir${Platform.pathSeparator}termpulse_prefs.json';
      _prefsPath = path;
      final file = File(path);
      if (!file.existsSync()) return;
      final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final langCode = map['language'] as String?;
      final themeName = map['themePreset'] as String?;
      final fontSize = (map['terminalFontSize'] as num?)?.toDouble();

      state = AppSettingsState(
        language: AppLanguage.values.where((l) => l.name == langCode).firstOrNull ?? AppLanguage.vi,
        themePreset: AppThemePreset.values.where((t) => t.name == themeName).firstOrNull ?? AppThemePreset.dark,
        terminalFontSize: (fontSize ?? 13.5).clamp(11.0, 20.0),
      );
    } catch (_) {}
  }

  Future<void> _saveToDisk() async {
    try {
      var path = _prefsPath;
      if (path == null) {
        final dir = await ForegroundBridge.getAppDataDir();
        path = '$dir${Platform.pathSeparator}termpulse_prefs.json';
        _prefsPath = path;
      }
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({
        'language': state.language.name,
        'themePreset': state.themePreset.name,
        'terminalFontSize': state.terminalFontSize,
      }));
    } catch (_) {}
  }

  void setLanguage(AppLanguage lang) {
    state = state.copyWith(language: lang);
    _saveToDisk();
  }

  void setThemePreset(AppThemePreset preset) {
    state = state.copyWith(themePreset: preset);
    _saveToDisk();
  }

  void toggleTheme() {
    setThemePreset(state.themePreset == AppThemePreset.dark ? AppThemePreset.light : AppThemePreset.dark);
  }

  void setTerminalFontSize(double size) {
    state = state.copyWith(terminalFontSize: size.clamp(11.0, 20.0));
    _saveToDisk();
  }
}

final settingsProvider =
    NotifierProvider<SettingsController, AppSettingsState>(SettingsController.new);

extension TermPulseL10nRef on WidgetRef {
  AppStrings get s => AppStrings(watch(settingsProvider).language);
}
