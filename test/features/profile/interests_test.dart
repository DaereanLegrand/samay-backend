import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/user_interests.dart';
import 'package:samay/features/profile/widgets/interests.dart';
import 'package:samay/l10n/app_localizations.dart';

/// PRFL interest-tags foundation tests (I-36): catalog integrity, the
/// [UserInterests] value-object contract (DB roundtrip, copy-on-write
/// mutation) and the [InterestTagPicker] toggle behavior.
///
/// Persistence is deliberately NOT wired yet — a `users.interest_tags text[]`
/// migration is required (see the I-36 daily log; migration agents I-31/I-32
/// own that). These tests pin the contract the migration will consume.
void main() {
  const expectedCatalog = <String>[
    'musica',
    'fiestas',
    'deportes',
    'gaming',
    'cine',
    'arte',
    'viajes',
    'comida',
  ];

  group('interest catalog', () {
    test('contains exactly the curated es tags (PRFL spec)', () {
      expect(kInterestTagIds, expectedCatalog);
    });

    test('ids are unique, lowercase ASCII slugs (no accented literals)', () {
      expect(kInterestTagIds.toSet().length, kInterestTagIds.length);
      for (final id in kInterestTagIds) {
        expect(RegExp(r'^[a-z]+$').hasMatch(id), isTrue,
            reason: '$id must be an ASCII lowercase slug');
      }
    });

    test('every id resolves to its localized Spanish label', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('es'));
      const labels = <String, String>{
        'musica': 'Música',
        'fiestas': 'Fiestas',
        'deportes': 'Deportes',
        'gaming': 'Gaming',
        'cine': 'Cine',
        'arte': 'Arte',
        'viajes': 'Viajes',
        'comida': 'Comida',
      };
      for (final id in kInterestTagIds) {
        expect(interestTagLabel(l10n, id), labels[id]);
      }
    });

    test('unknown ids throw ArgumentError', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('es'));
      expect(() => interestTagLabel(l10n, 'nope'), throwsArgumentError);
    });
  });

  group('UserInterests', () {
    test('defaults to an empty immutable selection', () {
      const interests = UserInterests();
      expect(interests.isEmpty, isTrue);
      expect(interests.tags, isEmpty);
      expect(UserInterests.empty.isEmpty, isTrue);
    });

    test('fromDb accepts the PostgREST list form', () {
      final interests =
          UserInterests.fromDb(<dynamic>['musica', 'cine', 'musica']);
      expect(interests.tags, {'musica', 'cine'});
    });

    test('fromDb accepts a JSON-encoded array string', () {
      final interests = UserInterests.fromDb('["deportes","arte"]');
      expect(interests.tags, {'deportes', 'arte'});
    });

    test('fromDb maps null and rejects malformed values', () {
      expect(UserInterests.fromDb(null).isEmpty, isTrue);
      expect(() => UserInterests.fromDb('not-json'), throwsFormatException);
      expect(() => UserInterests.fromDb(42), throwsFormatException);
    });

    test('toDb emits a sorted JSON array literal (deterministic)', () {
      expect(
        const UserInterests({'cine', 'musica'}).toDb(),
        '["cine","musica"]',
      );
      expect(UserInterests.empty.toDb(), '[]');
    });

    test('fromDb(toDb()) roundtrips for any selection', () {
      const selection = UserInterests({'viajes', 'comida', 'fiestas'});
      final roundtripped = UserInterests.fromDb(selection.toDb());
      expect(roundtripped, selection);
      expect(roundtripped.toDb(), selection.toDb());
    });

    test('copy-on-write mutation keeps the original untouched', () {
      const base = UserInterests({'musica'});
      final withMore = base.withTag('cine');
      final without = base.without('musica');
      final toggledOn = base.toggle('arte');
      final toggledOff = base.toggle('musica');

      expect(base.tags, {'musica'});
      expect(withMore.tags, {'musica', 'cine'});
      expect(without.isEmpty, isTrue);
      expect(toggledOn.tags, {'musica', 'arte'});
      expect(toggledOff.isEmpty, isTrue);
      expect(base.contains('musica'), isTrue);
      expect(base.contains('cine'), isFalse);
    });

    test('equality and hashCode are set-based', () {
      const a = UserInterests({'musica', 'cine'});
      const b = UserInterests({'cine', 'musica'});
      const c = UserInterests({'musica'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a.hashCode == c.hashCode, isFalse);
    });
  });

  group('InterestTagPicker', () {
    Widget harness(Widget child) => MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        );

    testWidgets('toggling a chip reports the full updated selection',
        (tester) async {
      // The picker is a controlled widget: the parent owns the selection and
      // feeds it back, exactly as the migration-based persistence wiring will.
      final selected = <String>{'musica'};
      await tester.pumpWidget(harness(
        StatefulBuilder(
          builder: (context, setState) => InterestTagPicker(
            selected: Set<String>.of(selected),
            onChanged: (next) => setState(() {
              selected
                ..clear()
                ..addAll(next);
            }),
          ),
        ),
      ));

      // Toggle "musica" off: the callback must carry the empty selection.
      await tester.tap(find.text('Música'));
      expect(selected, isEmpty);
      await tester.pump();

      // Toggle "deportes" on — recomputed from the parent-owned selection.
      await tester.tap(find.text('Deportes'));
      expect(selected, {'deportes'});
    });
  });
}
