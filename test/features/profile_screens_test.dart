import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/profile/screens/delete_account_screen.dart';
import 'package:samay/features/profile/screens/edit_profile_screen.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:samay/features/profile/screens/profile_screen.dart';
import 'package:samay/features/profile/screens/public_profile_screen.dart';
import 'package:samay/features/profile/screens/settings_screen.dart';
import 'package:samay/features/profile/widgets/profile_avatar.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

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

Future<void> _initFakeSupabase() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'http://127.0.0.1:54386',
    anonKey: 'test-anon-key',
    authOptions: FlutterAuthClientOptions(
      localStorage: _MemoryStorage(),
      pkceAsyncStorage: _MemoryAsyncStorage(),
      detectSessionInUri: false,
    ),
  );
}

class _StubProfileFetcher {
  _StubProfileFetcher(this._onFetch);

  final Future<Map<String, dynamic>?> Function() _onFetch;
  int calls = 0;

  Future<Map<String, dynamic>?> call() {
    calls++;
    return _onFetch();
  }
}

class _StubProfileNotifier extends MyProfileNotifier {
  _StubProfileNotifier(this.fetcher);

  final _StubProfileFetcher fetcher;

  @override
  Future<Map<String, dynamic>?> build() => fetcher.call();
}

class _StubGroupsFetcher {
  _StubGroupsFetcher(this._onFetch);

  final Future<List<Map<String, dynamic>>> Function() _onFetch;
  int calls = 0;

  Future<List<Map<String, dynamic>>> call() {
    calls++;
    return _onFetch();
  }
}

class _StubGroupsNotifier extends ProfileGroupsNotifier {
  _StubGroupsNotifier(this.fetcher);

  final _StubGroupsFetcher fetcher;

  @override
  Future<List<Map<String, dynamic>>> build() => fetcher.call();
}

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

Widget _wrapWithOverrides(Widget child, List<Override> overrides) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

/// Records sign-out calls without touching AuthService (R7): the real
/// notifier's `signOut()` runs the Supabase service; the settings confirm
/// dialog calls this instead so the test can assert cancel-vs-confirm.
class _SignOutAuthNotifier extends AuthNotifier {
  int signOutCalls = 0;

  @override
  Future<AuthState> build() async =>
      const AuthState(authenticated: true, hasProfile: true);

  @override
  Future<void> signOut() async {
    signOutCalls++;
    state = const AsyncData(AuthState());
  }
}

/// Minimal go_router for the profile/settings flow tests (R7/R8): the real
/// screens push with `context.push`/`context.go`, which need a router — the
/// plain `MaterialApp(home:)` harnesses cannot exercise those taps.
GoRouter _flowRouter(String path, Widget screen) {
  return GoRouter(
    initialLocation: path,
    routes: [
      GoRoute(path: path, builder: (_, _) => screen),
      if (path != RoutePaths.settings)
        GoRoute(path: RoutePaths.settings, builder: (_, _) => const SettingsScreen()),
      if (path != RoutePaths.profileEdit)
        GoRoute(path: RoutePaths.profileEdit, builder: (_, _) => const EditProfileScreen()),
      GoRoute(
        path: RoutePaths.login,
        builder: (_, _) => const Scaffold(
          body: Center(child: Text('LOGIN_PLACEHOLDER')),
        ),
      ),
    ],
  );
}

Widget _wrapRouter(Widget screen, {required String path, required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      routerConfig: _flowRouter(path, screen),
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

/// The settings list (grouped, R6) is taller than the 600px default viewport;
/// the flow tests use a phone-tall surface so every row is tappable without
/// scrolling.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUpAll(_initFakeSupabase);

  group('ProfileScreen', () {
    testWidgets('renders profile title', (tester) async {
      await tester.pumpWidget(_wrap(const ProfileScreen()));
      expect(find.text('Perfil'), findsOneWidget);
    });

    testWidgets('renders loading spinner then profile data', (tester) async {
      final profileFetcher = _StubProfileFetcher(
        () async => const {
          'username': 'dana',
          'bio': 'hola mundo',
          'personal_shards': 120,
          'preshards': 3,
        },
      );
      final groupsFetcher = _StubGroupsFetcher(
        () async => const [
          {'id': 'g1', 'name': 'Fiesta Club', 'group_shards': 42},
        ],
      );
      await tester.pumpWidget(
        _wrapWithOverrides(const ProfileScreen(), [
          myProfileProvider.overrideWith(
            () => _StubProfileNotifier(profileFetcher),
          ),
          myGroupsProvider.overrideWith(
            () => _StubGroupsNotifier(groupsFetcher),
          ),
        ]),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('dana'), findsOneWidget);
      expect(find.text('hola mundo'), findsOneWidget);
      expect(find.text('120 shards'), findsOneWidget);
      expect(find.text('3 preshards'), findsOneWidget);
      expect(find.text('Fiesta Club'), findsOneWidget);
      expect(find.text('42 shards'), findsOneWidget);
    });

    testWidgets('renders error state when the profile fetch fails', (
      tester,
    ) async {
      final profileFetcher = _StubProfileFetcher(
        () async => throw Exception('boom'),
      );
      final groupsFetcher = _StubGroupsFetcher(() async => const []);
      await tester.pumpWidget(
        _wrapWithOverrides(const ProfileScreen(), [
          myProfileProvider.overrideWith(
            () => _StubProfileNotifier(profileFetcher),
          ),
          myGroupsProvider.overrideWith(
            () => _StubGroupsNotifier(groupsFetcher),
          ),
        ]),
      );

      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(
        find.text('Error del servidor. Intenta de nuevo.'),
        findsOneWidget,
      );
    });

    testWidgets('pull-to-refresh re-fetches profile data', (tester) async {
      final profileFetcher = _StubProfileFetcher(
        () async => const {
          'username': 'dana',
          'personal_shards': 120,
          'preshards': 3,
        },
      );
      final groupsFetcher = _StubGroupsFetcher(() async => const []);
      await tester.pumpWidget(
        _wrapWithOverrides(const ProfileScreen(), [
          myProfileProvider.overrideWith(
            () => _StubProfileNotifier(profileFetcher),
          ),
          myGroupsProvider.overrideWith(
            () => _StubGroupsNotifier(groupsFetcher),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(profileFetcher.calls, 1);

      await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
      await tester.pumpAndSettle();
      expect(profileFetcher.calls, 2);
    });

    testWidgets(
      'cosmetics section renders nothing while the feature flag is off '
      '(PRFL gap — I-36: zero visual diff until COSM ships)',
      (tester) async {
        final profileFetcher = _StubProfileFetcher(
          () async => const {
            'username': 'dana',
            'personal_shards': 120,
            'preshards': 3,
          },
        );
        final groupsFetcher = _StubGroupsFetcher(() async => const []);
        await tester.pumpWidget(
          _wrapWithOverrides(const ProfileScreen(), [
            myProfileProvider.overrideWith(
              () => _StubProfileNotifier(profileFetcher),
            ),
            myGroupsProvider.overrideWith(
              () => _StubGroupsNotifier(groupsFetcher),
            ),
          ]),
        );
        await tester.pumpAndSettle();

        expect(find.text('Cosméticos'), findsNothing);
        expect(
          find.text('Tu armario de cosméticos aparecerá aquí.'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'cosmetics section renders as the shop entry row when the flag is '
      'enabled (I-62 — navigation covered in cosmetics_navigation_test)',
      (tester) async {
        final profileFetcher = _StubProfileFetcher(
          () async => const {
            'username': 'dana',
            'personal_shards': 120,
            'preshards': 3,
          },
        );
        final groupsFetcher = _StubGroupsFetcher(() async => const []);
        await tester.pumpWidget(
          _wrapWithOverrides(const ProfileScreen(), [
            myProfileProvider.overrideWith(
              () => _StubProfileNotifier(profileFetcher),
            ),
            myGroupsProvider.overrideWith(
              () => _StubGroupsNotifier(groupsFetcher),
            ),
            featureFlagsProvider.overrideWithValue(
              const AppFeatureFlags(cosmeticsSection: true),
            ),
          ]),
        );
        await tester.pumpAndSettle();

        // R9's VEmptyView (groups empty) grew the profile list — the
        // cosmetics row now sits below the 600px fold; scroll to it.
        await tester.scrollUntilVisible(find.text('Cosméticos'), 100);
        expect(find.text('Cosméticos'), findsOneWidget);
        expect(
          find.text('Tu armario de cosméticos aparecerá aquí.'),
          findsNothing,
        );
        // Both the balance card (I-64 ledger link) and the cosmetics row
        // carry the chevron affordance.
        expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
      },
    );
  });

  group('EditProfileScreen', () {
    testWidgets('renders edit form', (tester) async {
      await tester.pumpWidget(_wrap(const EditProfileScreen()));
      expect(find.text('Editar perfil'), findsOneWidget);
      expect(find.text('Biograf\u00eda'), findsOneWidget);
      expect(find.text('Guardar cambios'), findsOneWidget);
    });

    testWidgets('prefills the bio from myProfileProvider when available', (
      tester,
    ) async {
      final profileFetcher = _StubProfileFetcher(
        () async => const {
          'username': 'dana',
          'bio': 'bio desde provider',
          'personal_shards': 120,
          'preshards': 3,
        },
      );
      final groupsFetcher = _StubGroupsFetcher(() async => const []);
      await tester.pumpWidget(
        _wrapWithOverrides(const EditProfileScreen(), [
          myProfileProvider.overrideWith(
            () => _StubProfileNotifier(profileFetcher),
          ),
          myGroupsProvider.overrideWith(
            () => _StubGroupsNotifier(groupsFetcher),
          ),
        ]),
      );

      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'bio desde provider',
      );
    });
  });

  group('SettingsScreen', () {
    testWidgets('renders settings options', (tester) async {
      await tester.pumpWidget(_wrap(const SettingsScreen()));
      expect(find.text('Configuración'), findsOneWidget);
      expect(find.text('Suscripción'), findsOneWidget);
      // The settings list grew (I-65 Tema section); the sign-out row sits
      // below the 600px test viewport — scroll to it before asserting.
      await tester.scrollUntilVisible(find.text('Cerrar sesión'), 100);
      expect(find.text('Cerrar sesión'), findsOneWidget);
    });
  });

  group('SettingsScreen sign-out confirm (R7 — U-15 ledger)', () {
    testWidgets('cancel keeps the session and stays on settings', (tester) async {
      _useTallViewport(tester);
      final auth = _SignOutAuthNotifier();
      await tester.pumpWidget(_wrapRouter(
        const SettingsScreen(),
        path: RoutePaths.settings,
        overrides: [authStateProvider.overrideWith(() => auth)],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cerrar sesión'));
      await tester.pumpAndSettle();

      expect(find.text('¿Cerrar sesión?'), findsOneWidget,
          reason: 'R7 — sign-out gains the F8 confirm dialog (matches the '
              'delete-account dialog discipline)');
      expect(
        find.text('Tu sesión se cerrará en este dispositivo.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(auth.signOutCalls, 0, reason: 'cancel must not sign out');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Configuración'), findsOneWidget);
    });

    testWidgets('confirm signs out and returns to login', (tester) async {
      _useTallViewport(tester);
      final auth = _SignOutAuthNotifier();
      await tester.pumpWidget(_wrapRouter(
        const SettingsScreen(),
        path: RoutePaths.settings,
        overrides: [authStateProvider.overrideWith(() => auth)],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cerrar sesión'));
      await tester.pumpAndSettle();

      // The row label and the dialog action share the string — scope the
      // tap to the dialog (same pattern as the delete-account confirm).
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cerrar sesión'),
      ));
      await tester.pumpAndSettle();

      expect(auth.signOutCalls, 1);
      expect(find.text('LOGIN_PLACEHOLDER'), findsOneWidget,
          reason: 'the confirmed sign-out lands on the login route');
    });
  });

  group('ProfileScreen header tap-to-edit (R8 — U-15 ledger)', () {
    List<Override> overrides() => [
          myProfileProvider.overrideWith(
            () => _StubProfileNotifier(
              _StubProfileFetcher(
                () async => const {
                  'username': 'dana',
                  'bio': 'hola mundo',
                  'personal_shards': 120,
                  'preshards': 3,
                },
              ),
            ),
          ),
          myGroupsProvider.overrideWith(
            () => _StubGroupsNotifier(_StubGroupsFetcher(() async => const [])),
          ),
          authStateProvider.overrideWith(() => _SignOutAuthNotifier()),
        ];

    testWidgets('avatar tap opens the edit screen', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_wrapRouter(
        const ProfileScreen(),
        path: RoutePaths.mainProfile,
        overrides: overrides(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ProfileAvatar));
      await tester.pumpAndSettle();

      expect(find.byType(EditProfileScreen), findsOneWidget,
          reason: 'R8 — the avatar is the new tap-to-edit affordance '
              '(previously only reachable via the edit screen)');
      expect(find.text('Editar perfil'), findsWidgets);
    });

    testWidgets('username tap opens the edit screen', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_wrapRouter(
        const ProfileScreen(),
        path: RoutePaths.mainProfile,
        overrides: overrides(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('dana'));
      await tester.pumpAndSettle();

      expect(find.byType(EditProfileScreen), findsOneWidget);
      expect(find.text('Editar perfil'), findsWidgets);
    });
  });

  group('PublicProfileScreen', () {
    testWidgets('renders public profile', (tester) async {
      await tester.pumpWidget(
        _wrap(const PublicProfileScreen(userId: 'test-id')),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Usuario'), findsOneWidget);
      expect(find.text('Agregar amigo'), findsOneWidget);
    });
  });

  group('DeleteAccountScreen', () {
    testWidgets('renders delete account form', (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      expect(find.text('Eliminar cuenta'), findsWidgets);
      expect(find.textContaining('Confirma tu correo'), findsOneWidget);
    });

    testWidgets('tapping delete with empty email does nothing', (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      await tester.tap(find.text('Eliminar cuenta').last);
      await tester.pumpAndSettle();
      expect(find.text('¿Eliminar cuenta?'), findsNothing);
    });

    testWidgets(
      'tapping delete with wrong email does not show confirm dialog',
      (tester) async {
        await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
        await tester.enterText(find.byType(TextField), 'wrong@email.com');
        await tester.pump();
        await tester.tap(find.text('Eliminar cuenta').last);
        await tester.pumpAndSettle();
        expect(find.text('¿Eliminar cuenta?'), findsNothing);
      },
    );
  });
}
