import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/deep_links/deep_link_handler.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/l10n/app_localizations.dart';

class _MockRouter extends Mock implements GoRouter {}

class _MockEventService extends Mock implements EventService {}

Event _event(String id) => Event(
      id: id,
      name: 'Rave en el garaje',
      type: 'juerga',
      status: 'upcoming',
      startsAt: DateTime(2026, 5, 15, 21),
      endsAt: DateTime(2026, 5, 16, 2),
    );

void main() {
  group('DeepLinkHandler.parseDeepLink', () {
    const handler = DeepLinkHandler();

    test('parses samay://event/<token> links', () {
      final uri = handler.parseDeepLink('samay://event/abc-123');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'samay');
      expect(uri.host, 'event');
    });

    test('parses samay://event/<token> with a trailing slash', () {
      expect(handler.parseDeepLink('samay://event/abc-123/'), isNotNull);
    });

    test('parses the https universal-link fallback shape', () {
      final uri =
          handler.parseDeepLink('https://app.samay.example.com/event/abc-123');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, 'app.samay.example.com');
    });

    test('parses http for local/dev hosts', () {
      expect(handler.parseDeepLink('http://localhost:8080/event/abc-123'),
          isNotNull);
    });

    test('returns null for non-Samay links', () {
      expect(handler.parseDeepLink('mailto:test@example.com'), isNull);
      expect(handler.parseDeepLink('https://example.com/other/abc'), isNull);
      expect(handler.parseDeepLink('https://example.com/event/a/b'), isNull);
      expect(handler.parseDeepLink('https://example.com/event'), isNull);
      expect(handler.parseDeepLink('not a url'), isNull);
      expect(handler.parseDeepLink(''), isNull);
    });

    test('accepts any samay:// link at the scheme gate', () {
      // The scheme gate decides "is this a Samay link"; the event shape is
      // decided by [extractEventToken]. Future link types (profiles, etc.)
      // extend here without touching handleDeepLink.
      expect(handler.parseDeepLink('samay://profile/u1'), isNotNull);
    });
  });

  group('DeepLinkHandler.extractEventToken', () {
    const handler = DeepLinkHandler();

    test('extracts the token from samay://event/<token>', () {
      final uri = handler.parseDeepLink('samay://event/tok-1');
      expect(handler.extractEventToken(uri!), 'tok-1');
    });

    test('extracts the token from the https universal-link fallback', () {
      final uri =
          handler.parseDeepLink('https://app.samay.example.com/event/tok-2');
      expect(handler.extractEventToken(uri!), 'tok-2');
    });

    test('returns null for paths that are not event deep links', () {
      expect(handler.extractEventToken(Uri.parse('samay://profile/u1')), isNull);
      expect(handler.extractEventToken(Uri.parse('samay://event')), isNull);
      expect(handler.extractEventToken(Uri.parse('samay://event/')), isNull);
      expect(
          handler.extractEventToken(Uri.parse('samay://event/tok/extra')),
          isNull);
      expect(
          handler.extractEventToken(Uri.parse('https://x.com/other/tok')),
          isNull);
      expect(handler.extractEventToken(Uri.parse('https://x.com/event')),
          isNull);
      expect(
          handler.extractEventToken(Uri.parse('https://x.com/event/tok/extra')),
          isNull);
    });
  });

  group('DeepLinkHandler.handleDeepLink', () {
    const handler = DeepLinkHandler();

    test('resolves the token and navigates to the event detail route', () async {
      final router = _MockRouter();
      String? resolvedToken;
      final ok = await handler.handleDeepLink(
        'samay://event/tok-1',
        router: router,
        resolveEventId: (token) async {
          resolvedToken = token;
          return 'event-1';
        },
      );
      expect(ok, isTrue);
      expect(resolvedToken, 'tok-1');
      verify(() => router.go(RoutePaths.eventDetail('event-1'))).called(1);
    });

    test('supports the https universal-link fallback shape', () async {
      final router = _MockRouter();
      final ok = await handler.handleDeepLink(
        'https://app.samay.example.com/event/tok-2',
        router: router,
        resolveEventId: (_) async => 'event-2',
      );
      expect(ok, isTrue);
      verify(() => router.go(RoutePaths.eventDetail('event-2'))).called(1);
    });

    test('returns false without navigating for non-Samay links', () async {
      final router = _MockRouter();
      var resolveCalled = false;
      final ok = await handler.handleDeepLink(
        'https://example.com/other/x',
        router: router,
        resolveEventId: (_) async {
          resolveCalled = true;
          return 'event-1';
        },
      );
      expect(ok, isFalse);
      expect(resolveCalled, isFalse);
      verifyNever(() => router.go(any()));
    });

    test('returns false without navigating when the token is unknown', () async {
      final router = _MockRouter();
      final ok = await handler.handleDeepLink(
        'samay://event/unknown',
        router: router,
        resolveEventId: (_) async => null,
      );
      expect(ok, isFalse);
      verifyNever(() => router.go(any()));
    });

    test('returns false and swallows resolver errors', () async {
      final router = _MockRouter();
      final ok = await handler.handleDeepLink(
        'samay://event/tok-1',
        router: router,
        resolveEventId: (_) async => throw Exception('boom'),
      );
      expect(ok, isFalse);
      verifyNever(() => router.go(any()));
    });
  });

  group('DeepLinkHandler widget behavior', () {
    GoRouter eventRouter() => GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('home-marker')),
            ),
            GoRoute(
              path: '/event/:eventId',
              builder: (_, state) =>
                  Text('evt-${state.pathParameters['eventId']}'),
            ),
          ],
        );

    Future<void> pumpRouter(WidgetTester tester, GoRouter router) async {
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
    }

    testWidgets('navigates to the resolved event detail on success',
        (tester) async {
      final router = eventRouter();
      await pumpRouter(tester, router);
      final ok = await DeepLinkHandler().handleDeepLink(
        'samay://event/tok-1',
        router: router,
        resolveEventId: (_) async => 'event-1',
      );
      await tester.pumpAndSettle();
      expect(ok, isTrue);
      expect(find.text('evt-event-1'), findsOneWidget);
    });

    testWidgets('shows a localized snackbar when the token does not resolve',
        (tester) async {
      final router = eventRouter();
      await pumpRouter(tester, router);
      final ok = await DeepLinkHandler().handleDeepLink(
        'samay://event/unknown',
        router: router,
        resolveEventId: (_) async => null,
      );
      await tester.pump();
      expect(ok, isFalse);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.text('La invitaci\u00f3n solicitada no es v\u00e1lida.'),
        findsOneWidget,
      );
    });
  });

  group('DeepLinkListener (app_links seam)', () {
    GoRouter eventRouter() => GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('home-marker')),
            ),
            GoRoute(
              path: '/event/:eventId',
              builder: (_, state) =>
                  Text('evt-${state.pathParameters['eventId']}'),
            ),
          ],
        );

    testWidgets('forwards raw links from the injected stream to navigation',
        (tester) async {
      final controller = StreamController<String>();
      addTearDown(controller.close);
      final router = eventRouter();
      final service = _MockEventService();
      when(() => service.getEventByInviteToken('tok-1'))
          .thenAnswer((_) async => _event('event-1'));
      final container = ProviderContainer(overrides: [
        deepLinkStreamProvider.overrideWithValue(controller.stream),
        routerProvider.overrideWithValue(router),
        eventServiceProvider.overrideWithValue(service),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          // Mount the listener the same way SamayApp does: via the
          // MaterialApp.router builder (below Localizations, above Navigator).
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => Stack(
              children: [
                ?child,
                const DeepLinkListener(),
              ],
            ),
          ),
        ),
      );

      controller.add('samay://event/tok-1');
      await tester.pumpAndSettle();
      expect(find.text('evt-event-1'), findsOneWidget);
      verify(() => service.getEventByInviteToken('tok-1')).called(1);
    });

    testWidgets('is inert when the provider stream is null (default)',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const DeepLinkListener(),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(SizedBox), findsOneWidget);
    });
  });
}
