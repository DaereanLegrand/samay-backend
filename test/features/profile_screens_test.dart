import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/feed/feed_screen.dart';
import 'package:samay/features/profile/delete_account_screen.dart';
import 'package:samay/features/profile/edit_profile_screen.dart';
import 'package:samay/features/profile/profile_providers.dart';
import 'package:samay/features/profile/profile_screen.dart';
import 'package:samay/features/profile/public_profile_screen.dart';
import 'package:samay/features/profile/settings_screen.dart';
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
    url: 'http://localhost:54321',
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

void main() {
  setUpAll(_initFakeSupabase);

  group('ProfileScreen', () {
    testWidgets('renders profile title', (tester) async {
      await tester.pumpWidget(_wrap(const ProfileScreen()));
      expect(find.text('Perfil'), findsOneWidget);
    });

    testWidgets('renders loading spinner then profile data', (tester) async {
      final profileFetcher = _StubProfileFetcher(() async => const {
            'username': 'dana',
            'bio': 'hola mundo',
            'personal_shards': 120,
            'preshards': 3,
          });
      final groupsFetcher = _StubGroupsFetcher(() async => const [
            {'id': 'g1', 'name': 'Fiesta Club', 'group_shards': 42},
          ]);
      await tester.pumpWidget(_wrapWithOverrides(
        const ProfileScreen(),
        [
          myProfileProvider
              .overrideWith(() => _StubProfileNotifier(profileFetcher)),
          myGroupsProvider
              .overrideWith(() => _StubGroupsNotifier(groupsFetcher)),
        ],
      ));

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

    testWidgets('renders error state when the profile fetch fails',
        (tester) async {
      final profileFetcher =
          _StubProfileFetcher(() async => throw Exception('boom'));
      final groupsFetcher = _StubGroupsFetcher(() async => const []);
      await tester.pumpWidget(_wrapWithOverrides(
        const ProfileScreen(),
        [
          myProfileProvider
              .overrideWith(() => _StubProfileNotifier(profileFetcher)),
          myGroupsProvider
              .overrideWith(() => _StubGroupsNotifier(groupsFetcher)),
        ],
      ));

      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Error del servidor. Intenta de nuevo.'), findsOneWidget);
    });

    testWidgets('pull-to-refresh re-fetches profile data', (tester) async {
      final profileFetcher = _StubProfileFetcher(() async => const {
            'username': 'dana',
            'personal_shards': 120,
            'preshards': 3,
          });
      final groupsFetcher = _StubGroupsFetcher(() async => const []);
      await tester.pumpWidget(_wrapWithOverrides(
        const ProfileScreen(),
        [
          myProfileProvider
              .overrideWith(() => _StubProfileNotifier(profileFetcher)),
          myGroupsProvider
              .overrideWith(() => _StubGroupsNotifier(groupsFetcher)),
        ],
      ));
      await tester.pumpAndSettle();
      expect(profileFetcher.calls, 1);

      await tester.fling(
        find.byType(ListView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(profileFetcher.calls, 2);
    });

    testWidgets(
        'cosmetics section renders nothing while the feature flag is off '
        '(PRFL gap — I-36: zero visual diff until COSM ships)',
        (tester) async {
      final profileFetcher = _StubProfileFetcher(() async => const {
            'username': 'dana',
            'personal_shards': 120,
            'preshards': 3,
          });
      final groupsFetcher = _StubGroupsFetcher(() async => const []);
      await tester.pumpWidget(_wrapWithOverrides(
        const ProfileScreen(),
        [
          myProfileProvider
              .overrideWith(() => _StubProfileNotifier(profileFetcher)),
          myGroupsProvider
              .overrideWith(() => _StubGroupsNotifier(groupsFetcher)),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Cosméticos'), findsNothing);
      expect(find.text('Tu armario de cosméticos aparecerá aquí.'), findsNothing);
    });
  });

  group('EditProfileScreen', () {
    testWidgets('renders edit form', (tester) async {
      await tester.pumpWidget(_wrap(const EditProfileScreen()));
      expect(find.text('Editar perfil'), findsOneWidget);
      expect(find.text('Biograf\u00eda'), findsOneWidget);
      expect(find.text('Guardar cambios'), findsOneWidget);
    });

    testWidgets('prefills the bio from myProfileProvider when available',
        (tester) async {
      final profileFetcher = _StubProfileFetcher(() async => const {
            'username': 'dana',
            'bio': 'bio desde provider',
            'personal_shards': 120,
            'preshards': 3,
          });
      final groupsFetcher = _StubGroupsFetcher(() async => const []);
      await tester.pumpWidget(_wrapWithOverrides(
        const EditProfileScreen(),
        [
          myProfileProvider
              .overrideWith(() => _StubProfileNotifier(profileFetcher)),
          myGroupsProvider
              .overrideWith(() => _StubGroupsNotifier(groupsFetcher)),
        ],
      ));

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
      expect(find.text('Cerrar sesión'), findsOneWidget);
    });
  });

  group('PublicProfileScreen', () {
    testWidgets('renders public profile', (tester) async {
      await tester.pumpWidget(_wrap(
        const PublicProfileScreen(userId: 'test-id'),
      ));
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

    testWidgets('tapping delete with wrong email does not show confirm dialog',
        (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      await tester.enterText(find.byType(TextField), 'wrong@email.com');
      await tester.pump();
      await tester.tap(find.text('Eliminar cuenta').last);
      await tester.pumpAndSettle();
      expect(find.text('¿Eliminar cuenta?'), findsNothing);
    });
  });

  group('FeedScreen', () {
    testWidgets('renders welcome message', (tester) async {
      await tester.pumpWidget(_wrap(const FeedScreen()));
      expect(find.text('Bienvenido a Samay'), findsOneWidget);
    });
  });
}
