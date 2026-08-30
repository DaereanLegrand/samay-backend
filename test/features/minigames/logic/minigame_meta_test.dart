import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/features/minigames/logic/minigame_meta.dart';
import 'package:samay/l10n/app_localizations.dart';

/// Per-game metadata contract (2026-08-28 dedicated game pages):
///
/// * every [MinigameType] resolves a localized explanation + audience label
///   via the [MinigameMeta] extension — the shared `MinigameDetailScreen`
///   stays game-agnostic and new games only add a switch arm + l10n pair;
/// * [minigameTypeFromString] maps wire `game_type` strings back to the enum
///   (the router parses the `/minigames/game/:gameType` path segment with it);
/// * [minigameSessionName] resolves a session's display name — the user's
///   `name` when present, else the auto `partida-XX` running number.
void main() {
  const allTypes = MinigameType.values;

  group('MinigameMeta extension (per-game landing metadata)', () {
    test('every game type has a non-empty localized explanation', () {
      // l10n accessor is locale-agnostic here (es generated strings are
      // hard-wired) — we just pin that no type falls back to a blank value.
      final l10n = _stubL10n;
      for (final type in allTypes) {
        expect(
          type.explanation(l10n),
          isNotEmpty,
          reason: '${type.value} must carry an explanation',
        );
      }
    });

    test('challenge is both-capable; the rest are friends games', () {
      for (final type in allTypes) {
        expect(
          type.audience,
          type == MinigameType.challenge
              ? MinigameAudience.both
              : MinigameAudience.friends,
          reason: '${type.value} audience',
        );
      }
    });

    test('audience label resolves for every game type', () {
      final l10n = _stubL10n;
      for (final type in allTypes) {
        expect(type.audienceLabel(l10n), isNotEmpty);
      }
    });

    test('tagline resolves for every game type', () {
      final l10n = _stubL10n;
      for (final type in allTypes) {
        expect(type.tagline(l10n), isNotEmpty);
      }
    });
  });

  group('minigameTypeFromString (route parsing)', () {
    test('maps every wire value back to its enum', () {
      for (final type in allTypes) {
        expect(minigameTypeFromString(type.value), type);
      }
    });

    test('returns null for unknown/null values', () {
      expect(minigameTypeFromString('bogus'), isNull);
      expect(minigameTypeFromString(null), isNull);
    });
  });

  group('minigameSessionName (partida-XX auto-name)', () {
    Map<String, dynamic> session({String? name}) => {'name': name};

    test('uses the user-supplied name when present (trimmed)', () {
      expect(
        minigameSessionName(_stubL10n, session(name: '  La revancha ')),
        'La revancha',
      );
    });

    test('falls back to partida-{index+1} when the name is blank/null', () {
      expect(
        minigameSessionName(_stubL10n, session(), index: 0),
        'partida-1',
      );
      expect(
        minigameSessionName(_stubL10n, session(name: ''), index: 4),
        'partida-5',
      );
      expect(
        minigameSessionName(_stubL10n, session(name: '   '), index: 12),
        'partida-13',
      );
    });
  });
}

/// The generated l10n accessor resolves hard-wired strings per locale; the
/// tests only assert non-emptiness + enum-driven labels, so the es delegate
/// is a faithful stub.
final AppLocalizations _stubL10n = lookupAppLocalizations(const Locale('es'));
