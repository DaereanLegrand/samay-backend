import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/app.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/connectivity_service.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:yaml/yaml.dart';

const _esArb = 'lib/l10n/app_es.arb';
const _enArb = 'lib/l10n/app_en.arb';

final _placeholderPattern = RegExp(r'\{(\w+)\}');

Map<String, dynamic> _loadArb(String path) {
  final raw = File(path).readAsStringSync();
  final yaml = loadYaml(raw);
  return Map<String, dynamic>.from(yaml as YamlMap);
}

Set<String> _messageKeys(Map<String, dynamic> arb) {
  return arb.keys.where((k) => !k.startsWith('@')).toSet();
}

Set<String> _placeholdersIn(String message) {
  return _placeholderPattern
      .allMatches(message)
      .map((m) => m.group(1)!)
      .toSet();
}

Map<String, dynamic> _placeholderMetadata(Map<String, dynamic> arb, String key) {
  final metadata = arb['@$key'];
  if (metadata is Map) {
    final placeholders = metadata['placeholders'];
    if (placeholders is Map) {
      return Map<String, dynamic>.from(placeholders);
    }
  }
  return const {};
}

class _StubAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState();
}

void main() {
  group('ARB key parity', () {
    final es = _loadArb(_esArb);
    final en = _loadArb(_enArb);
    final esKeys = _messageKeys(es);
    final enKeys = _messageKeys(en);

    test('every key in app_es.arb exists in app_en.arb', () {
      final missing = esKeys.difference(enKeys);
      expect(missing, isEmpty, reason: 'es keys missing from en: $missing');
    });

    test('every key in app_en.arb exists in app_es.arb', () {
      final missing = enKeys.difference(esKeys);
      expect(missing, isEmpty, reason: 'en keys missing from es: $missing');
    });

    test('every message key has a metadata entry in both files', () {
      for (final key in esKeys) {
        expect(es.containsKey('@$key'), isTrue,
            reason: 'es missing metadata for $key');
        expect(en.containsKey('@$key'), isTrue,
            reason: 'en missing metadata for $key');
      }
    });

    test('message placeholders match the @metadata placeholders', () {
      for (final key in esKeys) {
        final esMessage = es[key]! as String;
        final esInMessage = _placeholdersIn(esMessage);
        final esMetadata = _placeholderMetadata(es, key).keys.toSet();
        expect(esInMessage, esMetadata,
            reason: 'es placeholders mismatch for $key');
        final enMessage = en[key]! as String;
        final enInMessage = _placeholdersIn(enMessage);
        final enMetadata = _placeholderMetadata(en, key).keys.toSet();
        expect(enInMessage, enMetadata,
            reason: 'en placeholders mismatch for $key');
      }
    });

    test('placeholder sets match between the two files', () {
      for (final key in esKeys) {
        final esPlaceholders = _placeholdersIn(es[key]! as String);
        final enPlaceholders = _placeholdersIn(en[key]! as String);
        expect(enPlaceholders, esPlaceholders,
            reason: 'placeholder sets differ for $key');
      }
    });

    test('both ARB files are valid JSON', () {
      for (final path in [_esArb, _enArb]) {
        final raw = File(path).readAsStringSync();
        expect(() => jsonDecode(raw), returnsNormally,
            reason: '$path must be valid JSON');
      }
    });
  });

  group('typed accessors for the demo keys', () {
    test('es locale exposes the welcome and coming-soon accessors', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('es'));
      expect(l10n.welcomeVive, 'vive');
      expect(l10n.welcomeTagline, 'Tu vida social, en un solo lugar');
      expect(l10n.commonCreateAccount, 'Crear cuenta');
      expect(l10n.commonSignIn, 'Iniciar sesión');
      expect(l10n.comingSoonSoon, 'Pr\u00f3ximamente');
      expect(l10n.comingSoonBack, 'Volver');
    });

    test('en locale exposes the same accessors', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(l10n.welcomeVive, 'vive');
      expect(l10n.welcomeTagline, 'Your social life, all in one place');
      expect(l10n.commonCreateAccount, 'Create account');
      expect(l10n.comingSoonSoon, 'Coming soon');
    });

    test('parameterized accessors interpolate placeholders', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('es'));
      expect(
        l10n.groupsDonateTo('Mi Grupo'),
        'Donar a Mi Grupo',
      );
      expect(
        l10n.authSelectedDate(15, 1, 2000),
        '15/1/2000',
      );
      expect(
        l10n.errorsNotFound('Grupo'),
        'Grupo no encontrado.',
      );
    });
  });

  group('app locale wiring', () {
    testWidgets('SamayApp renders under the es locale on the welcome route',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(_StubAuthNotifier.new),
          // I-67: inert connectivity seam (plugin-free test environment).
          connectivityServiceProvider.overrideWithValue(
            ConnectivityService(
              onConnectivityChanged: () => Stream<bool>.multi((_) {}),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(routerProvider).go(RoutePaths.welcome);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SamayApp(),
        ),
      );
      await tester.pumpAndSettle();

      final context = tester.element(find.text('vive'));
      expect(Localizations.localeOf(context), const Locale('es'));
      expect(find.text('vive'), findsOneWidget);
      expect(find.text('Tu vida social, en un solo lugar'), findsOneWidget);
      expect(find.text('Crear cuenta'), findsOneWidget);
      expect(find.text('Iniciar sesión'), findsOneWidget);
    });
  });
}
