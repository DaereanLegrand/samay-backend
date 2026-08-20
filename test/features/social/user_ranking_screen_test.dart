import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/social/providers/social_providers.dart';
import 'package:samay/features/social/screens/user_ranking_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

import '../../support/fake_config_provider.dart';

class _StubRanking extends UserRankingNotifier {
  _StubRanking(this.entries);

  final List<UserRankingEntry> entries;

  @override
  Future<List<UserRankingEntry>> build() async => entries;
}

Future<void> _pump(
  WidgetTester tester, {
  required Map<String, String> config,
  required List<UserRankingEntry> entries,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userRankingProvider.overrideWith(() => _StubRanking(entries)),
        appConfigProvider.overrideWith(() => FakeAppConfigNotifier(config)),
      ],
      child: MaterialApp(
        theme: SamayTheme.dark,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const UserRankingScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

UserRankingEntry _entry(String name, {bool profilePublic = false}) =>
    UserRankingEntry(
      userId: 'u-${name.hashCode}',
      username: name,
      avatarUrl: null,
      personalShards: 100,
      profilePublic: profilePublic,
    );

const _private = {'ranking.anonymize_names': 'true'};
const _public = {'ranking.anonymize_names': 'false'};

void main() {
  testWidgets('censored: anonymize on + private profile shows the placeholder',
      (tester) async {
    await _pump(tester, config: _private, entries: [_entry('ana')]);

    expect(find.text('ana'), findsNothing);
    expect(find.text('Usuario'), findsOneWidget);
  });

  testWidgets('anonymize on + public profile shows the username',
      (tester) async {
    await _pump(
      tester,
      config: _private,
      entries: [_entry('ana', profilePublic: true)],
    );

    expect(find.text('ana'), findsOneWidget);
  });

  testWidgets('anonymize off shows the username regardless of privacy',
      (tester) async {
    await _pump(tester, config: _public, entries: [_entry('ana')]);

    expect(find.text('ana'), findsOneWidget);
  });
}
