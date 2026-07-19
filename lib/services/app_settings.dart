import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  AppSettings._();

  static final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
  static const _themeKey = 'theme_mode';

  static Future<void> initialize() async {
    final preferences = SharedPreferencesAsync();
    final stored = await preferences.getString(_themeKey);
    themeMode.value = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    final preferences = SharedPreferencesAsync();
    await preferences.setString(_themeKey, mode.name);
  }
}
