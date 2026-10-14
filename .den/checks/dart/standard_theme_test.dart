// Acceptance: clarity/standard-theme. PROTECTED (.den/**); copied into budget/test/den_accept/ by
// check_standard_theme.sh. Brian, 2026-10-14: "Change the theme back to more standard, ditch the
// 8bit. I don't like it." The app's ThemeData must be plain Material 3: M3 (2021) typography, no
// pixel font, and no Clarity purple (#433187) as the out-of-the-box accent. getLightTheme() and
// getDarkTheme() must work with exactly the settings keys below (today's colors.dart reads these).
import 'package:budget/colors.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const purple = Color(0xFF433187);

Map<String, dynamic> settings(String accentHex) => {
      "font": "Inter",
      "materialYou": true,
      "accentColor": accentHex,
      "accentSystemColor": false,
      "theme": "system",
      "forceFullDarkBackground": false,
      "batterySaver": false,
      "increaseTextContrast": false,
      "iOSNavigation": false,
    };

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    test('$b theme is Material 3 with 2021 typography', () {
      appStateSettings = settings("0xff1b447a");
      final t = b == Brightness.light ? getLightTheme() : getDarkTheme();
      expect(t.useMaterial3, isTrue);
      expect(t.typography.englishLike, Typography.englishLike2021);
      expect(t.typography.dense, Typography.dense2021);
      expect(t.typography.tall, Typography.tall2021);
    });

    test('$b theme uses no pixel font', () {
      appStateSettings = settings("0xff1b447a");
      final t = b == Brightness.light ? getLightTheme() : getDarkTheme();
      final fam = <String?>[
        t.textTheme.bodyMedium?.fontFamily,
        t.textTheme.titleLarge?.fontFamily,
        ...?t.textTheme.bodyMedium?.fontFamilyFallback,
      ].whereType<String>().map((s) => s.toLowerCase());
      for (final f in fam) {
        expect(f.contains('pixel'), isFalse, reason: 'font family $f');
      }
    });
  }

  test('the fallback accent is not the 8-bit purple', () {
    expect(kDefaultAccentColor, isNot(purple));
    expect(kDefaultAccentColor.alpha, 255);
  });
}
