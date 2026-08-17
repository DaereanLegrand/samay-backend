import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/features/events/screens/event_detail_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/route_error_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

const _eventId = '11111111-1111-1111-1111-111111111111';
const _token = 'invite-tok-1';

Event _event() => Event(
  id: _eventId,
  name: 'Rave en el garaje',
  description: 'La mejor fiesta del barrio',
  type: 'juerga',
  status: 'upcoming',
  createdByUserId: _eventId,
  locationName: 'Av. Los Aromos 123',
  startsAt: DateTime(2026, 5, 15, 21),
  endsAt: DateTime(2026, 5, 16, 2),
  joinMode: 'open',
  preshardsPool: 500,
);

class _MockEventService extends Mock implements EventService {}

class _FakeAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async =>
      const AuthState(authenticated: true, hasProfile: true);
}

class _MemoryStorage extends LocalStorage {
  String? _token;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => _token != null;

  @override
  Future<String?> accessToken() async => _token;

  @override
  Future<void> persistSession(String persistSessionString) async {
    _token = persistSessionString;
  }

  @override
  Future<void> removePersistedSession() async {
    _token = null;
  }
}

class _MemoryAsyncStorage extends GotrueAsyncStorage {
  final Map<String, String> _items = {};

  @override
  Future<String?> getItem({required String key}) async => _items[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    _items[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    _items.remove(key);
  }
}

/// Pumps the REAL router (routerProvider) with the auth pinned to a signed-in
/// state and the EventService replaced by [service] — the detail screen and
/// the invite-token resolution both run through the real provider stack.
Future<void> _pumpRoute(
  WidgetTester tester,
  String path,
  EventService service, {
  bool settle = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _FakeAuthNotifier()),
      eventServiceProvider.overrideWithValue(service),
    ],
  );
  addTearDown(container.dispose);
  final router = container.read(routerProvider);
  router.go(path);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUpAll(() async {
    await Supabase.initialize(
      url: 'http://127.0.0.1:54386',
      anonKey: 'test-anon-key',
      authOptions: FlutterAuthClientOptions(
        localStorage: _MemoryStorage(),
        pkceAsyncStorage: _MemoryAsyncStorage(),
        detectSessionInUri: false,
      ),
    );
  });

  group('/event/:eventId invite-token resolution (I-66)', () {
    testWidgets('a UUID param renders the detail screen directly without token '
        'resolution', (tester) async {
      final service = _MockEventService();
      when(() => service.getEvent(_eventId)).thenAnswer((_) async => _event());
      when(
        () => service.getEventPromotores(_eventId),
      ).thenAnswer((_) async => <Map<String, dynamic>>[]);
      when(
        () => service.getMyEventInvite(_eventId),
      ).thenAnswer((_) async => null);

      await _pumpRoute(tester, RoutePaths.eventDetail(_eventId), service);

      expect(find.byType(EventDetailScreen), findsOneWidget);
      expect(find.text('RAVE EN EL GARAJE'), findsOneWidget);
      verifyNever(() => service.getEventByInviteToken(any()));
    });

    testWidgets(
      'a non-UUID invite token resolves through the service to the detail '
      'screen',
      (tester) async {
        final service = _MockEventService();
        when(
          () => service.getEventByInviteToken(_token),
        ).thenAnswer((_) async => _event());
        when(
          () => service.getEvent(_eventId),
        ).thenAnswer((_) async => _event());
        when(
          () => service.getEventPromotores(_eventId),
        ).thenAnswer((_) async => <Map<String, dynamic>>[]);
        when(
          () => service.getMyEventInvite(_eventId),
        ).thenAnswer((_) async => null);

        await _pumpRoute(tester, RoutePaths.eventInviteToken(_token), service);

        expect(find.byType(EventDetailScreen), findsOneWidget);
        expect(find.text('RAVE EN EL GARAJE'), findsOneWidget);
        verify(() => service.getEventByInviteToken(_token)).called(1);
        // The detail is fetched by the RESOLVED id, not the raw token.
        verify(() => service.getEvent(_eventId)).called(1);
      },
    );

    testWidgets('an unknown invite token renders the not-found state', (
      tester,
    ) async {
      final service = _MockEventService();
      when(
        () => service.getEventByInviteToken('unknown-token'),
      ).thenAnswer((_) async => null);

      await _pumpRoute(
        tester,
        RoutePaths.eventInviteToken('unknown-token'),
        service,
      );

      // LUXE restyle: the not-found fallback is the VEmptyView state (peach
      // accent), not the generic RouteErrorScreen.
      expect(find.byType(VEmptyView), findsOneWidget);
      expect(
        find.text('La invitaci\u00f3n solicitada no es v\u00e1lida.'),
        findsOneWidget,
      );
      expect(find.byType(EventDetailScreen), findsNothing);
    });

    testWidgets(
      'a failing token resolution renders the error view with retry',
      (tester) async {
        final service = _MockEventService();
        when(
          () => service.getEventByInviteToken('boom-token'),
        ).thenThrow(Exception('network down'));

        await _pumpRoute(
          tester,
          RoutePaths.eventInviteToken('boom-token'),
          service,
        );

        expect(find.byType(ErrorView), findsOneWidget);
        expect(find.byType(EventDetailScreen), findsNothing);
      },
    );

    testWidgets('shows a loading state while the token resolves', (
      tester,
    ) async {
      final service = _MockEventService();
      final completer = Completer<Event>();
      when(
        () => service.getEventByInviteToken('slow-token'),
      ).thenAnswer((_) => completer.future);

      await _pumpRoute(
        tester,
        RoutePaths.eventInviteToken('slow-token'),
        service,
        settle: false,
      );

      expect(find.byType(VLoadingView), findsOneWidget);
      expect(find.byType(EventDetailScreen), findsNothing);

      completer.complete(_event());
      await tester.pumpAndSettle();
      expect(find.byType(EventDetailScreen), findsOneWidget);
    });

    testWidgets('an empty param renders the not-found state without crashing', (
      tester,
    ) async {
      final service = _MockEventService();

      await _pumpRoute(tester, '/event/', service);

      expect(find.byType(RouteErrorScreen), findsOneWidget);
      verifyNever(() => service.getEventByInviteToken(any()));
    });
  });
}
