import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Manages locale resolution, switching, and i18n resource loading for the Beauty SDK.
///
/// Supports 6 locales: en_US, zh_CN, zh_TW, zh_HK, ko_KR, vi_VN.
/// Falls back to en_US for unsupported locales.
class BeautyLocale {
  BeautyLocale._();

  static final BeautyLocale _instance = BeautyLocale._();

  /// Singleton instance.
  static BeautyLocale get instance => _instance;

  /// Supported locale list.
  static const List<String> supportedLocales = [
    'en_US',
    'zh_CN',
    'zh_TW',
    'zh_HK',
    'ko_KR',
    'vi_VN',
  ];

  /// Default fallback locale.
  static const String defaultLocale = 'en_US';

  /// Platform channel for propagating locale to native layers.
  static const MethodChannel _channel =
      MethodChannel('com.orangecloud.beautysdk/method');

  String _currentLocale = defaultLocale;
  Map<String, dynamic> _strings = {};
  bool _initialized = false;

  /// Current active locale.
  String get currentLocale => _currentLocale;

  /// Whether the locale system has been initialized.
  bool get isInitialized => _initialized;

  /// Initialize the locale system.
  ///
  /// If [locale] is provided and supported, uses it directly.
  /// Otherwise resolves from the device system locale.
  Future<void> initialize({String? locale}) async {
    final resolved = locale != null
        ? resolveLocale(locale)
        : _resolveSystemLocale();
    _currentLocale = resolved;
    await _loadStrings(resolved);
    _initialized = true;
  }

  /// Resolve a locale string to a supported locale.
  ///
  /// Returns [locale] if it is in the supported list, otherwise returns [defaultLocale].
  static String resolveLocale(String locale) {
    if (supportedLocales.contains(locale)) {
      return locale;
    }
    return defaultLocale;
  }

  /// Set locale at runtime. Takes effect immediately without re-initialization.
  ///
  /// Propagates the locale setting to iOS/Android native layers via Platform Channel.
  Future<void> setLocale(String locale) async {
    final resolved = resolveLocale(locale);
    _currentLocale = resolved;
    await _loadStrings(resolved);
    // Propagate to native layers
    try {
      await _channel.invokeMethod('setLocale', {'locale': resolved});
    } catch (_) {
      // Native layer may not be initialized yet; ignore.
    }
  }

  /// Get a localized error message by error code.
  String getError(String code) {
    final errors = _strings['errors'] as Map<String, dynamic>?;
    return errors?[code]?.toString() ?? code;
  }

  /// Get a localized filter name by filter key.
  String getFilter(String key) {
    final filters = _strings['filters'] as Map<String, dynamic>?;
    return filters?[key]?.toString() ?? key;
  }

  /// Get a localized string by section and key.
  String getString(String section, String key) {
    final sectionMap = _strings[section] as Map<String, dynamic>?;
    return sectionMap?[key]?.toString() ?? key;
  }

  /// Resolve system locale to a supported locale.
  String _resolveSystemLocale() {
    final systemLocale = ui.PlatformDispatcher.instance.locale;
    final candidate =
        '${systemLocale.languageCode}_${systemLocale.countryCode ?? ''}';
    return resolveLocale(candidate);
  }

  /// Load i18n strings from the JSON asset file for the given locale.
  Future<void> _loadStrings(String locale) async {
    try {
      final jsonStr =
          await rootBundle.loadString('assets/i18n/$locale.json');
      _strings = json.decode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      // If loading fails and not already default, try loading default locale.
      if (locale != defaultLocale) {
        try {
          final jsonStr =
              await rootBundle.loadString('assets/i18n/$defaultLocale.json');
          _strings = json.decode(jsonStr) as Map<String, dynamic>;
          _currentLocale = defaultLocale;
        } catch (_) {
          _strings = {};
        }
      } else {
        _strings = {};
      }
    }
  }
}
