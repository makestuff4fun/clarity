#!/usr/bin/env bash
# Acceptance: clarity/standard-theme. PROTECTED. Brian, 2026-10-14: "Change the theme back to more
# standard, ditch the 8bit. I don't like it."
#  1. source: no Clarity purple (#433187 / 0xFF433187) left in lib/ or web/ (the launcher icon's
#     background is the app-icon task's), no Typography.material2014, no pixel font anywhere in
#     pubspec or assets/fonts, the default accent and the fresh-install defaults use
#     kDefaultAccentColor, and a one-shot "migratedToStandardTheme" settings migration exists.
#  2. the protected Dart test (.den/checks/dart/standard_theme_test.dart, >= 5 tests) passes:
#     getLightTheme()/getDarkTheme() are M3 with 2021 typography, no pixel font, accent not purple.
source "$(dirname "$0")/flutter_common.sh"
L="$B/lib"
hits=$(grep -rniI -e '433187' "$L" "$B/web" || true)
[ -z "$hits" ] || die "the 8-bit purple is still in lib/ or web/:
$hits"
hits=$(grep -rn 'Typography.material2014' "$L" || true)
[ -z "$hits" ] || die "M2 (2014) typography is still used:
$hits"
hits=$( { grep -niE 'pixel|8.?bit|press.?start|silkscreen' "$B/pubspec.yaml" || true; ls "$B/assets/fonts" | grep -iE 'pixel|8.?bit|press.?start|silkscreen' || true; } )
[ -z "$hits" ] || die "a pixel font is still bundled or referenced: $hits"
grep -q 'kDefaultAccentColor' "$L/colors.dart" || die "lib/colors.dart must define kDefaultAccentColor (the standard fallback accent)"
grep -q 'kDefaultAccentColor' "$L/struct/defaultPreferences.dart" || die "defaultPreferences.dart's accentColor must use kDefaultAccentColor"
grep -q 'migratedToStandardTheme' "$L/struct/settings.dart" || die "no one-shot migratedToStandardTheme migration in lib/struct/settings.dart (installs carrying the purple keep it otherwise)"
run_dart_tests standard_theme 5 "$CHK/dart/standard_theme_test.dart"
echo "standard-theme OK"
