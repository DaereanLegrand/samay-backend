import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/auth_service.dart';
import 'package:samay/core/services/ban_service.dart';
import 'package:samay/features/auth/screens/banned_screen.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

class _FakeAuthService extends Mock implements AuthService {}

class _FakeBanService extends Mock implements BanService {}

const _user = {
  'id': '11111111-1111-1111-1111-111111111111',
  'email': 'a@b.com',
};

/// AuthService stub: no auth events, profile probe succeeds, `getCurrentUser`
/// resolves through [userSequence] (null → _user style replayable sequences).
AuthService _stubbedAuthService({
  List<Map<String, dynamic>?> userSequence = const [null],
}) {
  final queue = [...userSequence];
  final service = _FakeAuthService();
  when(() => service.onAuthStateChange).thenAnswer((_) => const Stream.empty());
  when(() => service.userHasProfile(any())).thenAnswer((_) async => true);
  when(() => service.signIn(any(), any())).thenAnswer((_) async {});
  when(() => service.signOut()).thenAnswer((_) async {});
  when(() => service.getCurrentUser()).thenAnswer((_) => queue.removeAt(0));
  return service;
}

BanService _stubbedBanService([BanStatus status = BanStatus.notBanned]) {
  final service = _FakeBanService();
  when(
    () => service.checkBanStatus(force: any(named: 'force')),
  ).thenAnswer((_) async => status);
  return service;
}

ProviderContainer _newContainer({
  required AuthService authService,
  required BanService banService,
}) {
  final container = ProviderContainer(
    overrides: [
      authServiceProvider.overrideWithValue(authService),
      banServiceProvider.overrideWithValue(banService),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Fake notifier pinned to a banned state (used by the screen/router tests —
/// mirrors the `_FakeAuthNotifier` pattern in `test/router/app_router_test.dart`).
class _BannedAuthNotifier extends AuthNotifier {
  _BannedAuthNotifier({this.reason = 'Test reason'});

  final String? reason;

  @override
  Future<AuthState> build() async => AuthState(banned: true, banReason: reason);
}

Widget _wrapWithL10n(Widget child) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  group('AuthNotifier — ban enforcement', () {
    test(
      'session restore with a banned profile lands on the banned state',
      () async {
        final authService = _stubbedAuthService(userSequence: [_user]);
        final banService = _stubbedBanService(
          const BanStatus.banned('Motivo de prueba'),
        );
        final container = _newContainer(
          authService: authService,
          banService: banService,
        );

        await container.read(authStateProvider.future);

        final state = container.read(authStateProvider);
        expect(state.valueOrNull?.banned, isTrue);
        expect(state.valueOrNull?.authenticated, isFalse);
        expect(state.valueOrNull?.banReason, 'Motivo de prueba');
        verify(() => authService.signOut()).called(1);
      },
    );

    test(
      'signIn with a banned profile signs out and sets the banned state',
      () async {
        final authService = _stubbedAuthService(userSequence: [null, _user]);
        final banService = _stubbedBanService(
          const BanStatus.banned('Motivo de prueba'),
        );
        final container = _newContainer(
          authService: authService,
          banService: banService,
        );
        await container.read(authStateProvider.future);

        await container
            .read(authStateProvider.notifier)
            .signIn('a@b.com', 'secret1');

        final state = container.read(authStateProvider);
        expect(state.hasValue, isTrue);
        expect(state.hasError, isFalse);
        expect(state.valueOrNull?.banned, isTrue);
        expect(state.valueOrNull?.authenticated, isFalse);
        expect(state.valueOrNull?.banReason, 'Motivo de prueba');
        verify(() => authService.signOut()).called(1);
      },
    );

    test('verifyOtp with a banned profile lands on the banned state', () async {
      final authService = _stubbedAuthService(userSequence: [null, _user]);
      final banService = _stubbedBanService(
        const BanStatus.banned('Motivo de prueba'),
      );
      when(() => authService.verifyOtp(any(), any())).thenAnswer((_) async {});
      final container = _newContainer(
        authService: authService,
        banService: banService,
      );
      await container.read(authStateProvider.future);

      await container
          .read(authStateProvider.notifier)
          .verifyOtp('a@b.com', '123456');

      final state = container.read(authStateProvider);
      expect(state.valueOrNull?.banned, isTrue);
      expect(state.valueOrNull?.authenticated, isFalse);
      verify(() => authService.signOut()).called(1);
    });

    test('signIn with a healthy profile authenticates normally', () async {
      final authService = _stubbedAuthService(userSequence: [null, _user]);
      final banService = _stubbedBanService();
      final container = _newContainer(
        authService: authService,
        banService: banService,
      );
      await container.read(authStateProvider.future);

      await container
          .read(authStateProvider.notifier)
          .signIn('a@b.com', 'secret1');

      final state = container.read(authStateProvider);
      expect(state.valueOrNull?.authenticated, isTrue);
      expect(state.valueOrNull?.banned, isFalse);
      expect(state.valueOrNull?.user?['id'], _user['id']);
      verifyNever(() => authService.signOut());
    });

    test(
      'a failing ban check does not block authentication (fail-open)',
      () async {
        final authService = _stubbedAuthService(userSequence: [null, _user]);
        final banService = _FakeBanService();
        when(
          () => banService.checkBanStatus(force: any(named: 'force')),
        ).thenThrow(Exception('check unavailable'));
        final container = _newContainer(
          authService: authService,
          banService: banService,
        );
        await container.read(authStateProvider.future);

        await container
            .read(authStateProvider.notifier)
            .signIn('a@b.com', 'secret1');

        final state = container.read(authStateProvider);
        expect(state.valueOrNull?.authenticated, isTrue);
        expect(state.valueOrNull?.banned, isFalse);
        verifyNever(() => authService.signOut());
      },
    );
  });

  group('BannedScreen', () {
    testWidgets('renders the suspension title, body and logout action', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(
            () => _BannedAuthNotifier(reason: null),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _wrapWithL10n(const BannedScreen()),
        ),
      );

      expect(find.text('CUENTA SUSPENDIDA'), findsOneWidget);
      expect(find.text('Tu cuenta ha sido suspendida.'), findsOneWidget);
      expect(find.text('Cerrar sesión'), findsOneWidget);
    });

    testWidgets('renders the stored ban reason when present', (tester) async {
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(
            () => _BannedAuthNotifier(reason: 'Spam'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _wrapWithL10n(const BannedScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Motivo: Spam'), findsOneWidget);
      expect(find.text('Tu cuenta ha sido suspendida.'), findsNothing);
    });

    testWidgets('logout signs the user out', (tester) async {
      final authService = _FakeAuthService();
      when(() => authService.signOut()).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(() => _BannedAuthNotifier()),
          authServiceProvider.overrideWithValue(authService),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _wrapWithL10n(const BannedScreen()),
        ),
      );

      await tester.tap(find.text('Cerrar sesión'));
      await tester.pump();

      verify(() => authService.signOut()).called(1);
    });
  });

  group('AuthGuard — banned redirect', () {
    ProviderContainer routerContainer() {
      final container = ProviderContainer(
        overrides: [authStateProvider.overrideWith(_BannedAuthNotifier.new)],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<void> pumpRoute(
      WidgetTester tester,
      ProviderContainer container,
      String path,
    ) async {
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
      await tester.pumpAndSettle();
    }

    testWidgets('a banned user is redirected from an authenticated route', (
      tester,
    ) async {
      final container = routerContainer();
      await pumpRoute(tester, container, RoutePaths.mainFeed);

      expect(find.byType(BannedScreen), findsOneWidget);
      expect(find.byType(FeedScreen), findsNothing);
    });

    testWidgets('a banned user is redirected from a public route too', (
      tester,
    ) async {
      final container = routerContainer();
      await pumpRoute(tester, container, RoutePaths.welcome);

      expect(find.byType(BannedScreen), findsOneWidget);
    });

    testWidgets('the ban route itself renders without a redirect loop', (
      tester,
    ) async {
      final container = routerContainer();
      await pumpRoute(tester, container, RoutePaths.banned);

      expect(find.byType(BannedScreen), findsOneWidget);
    });
  });
}
