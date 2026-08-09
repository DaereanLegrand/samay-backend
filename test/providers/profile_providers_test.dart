import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/profile/profile_providers.dart';
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

/// Call-tracking stub fetch for the profile provider. Lives outside the
/// notifier because Riverpod rebuilds the notifier on invalidation — the
/// counter must survive provider recreation.
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

void main() {
  setUpAll(_initFakeSupabase);

  group('myProfileProvider', () {
    test('returns AsyncData with the profile row on success', () async {
      final fetcher = _StubProfileFetcher(() async => const {
            'username': 'dana',
            'bio': 'hola mundo',
            'personal_shards': 120,
            'preshards': 3,
          });
      final container = ProviderContainer(
        overrides: [
          myProfileProvider.overrideWith(() => _StubProfileNotifier(fetcher)),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(myProfileProvider.future);
      expect(state?['username'], 'dana');
      expect(state?['bio'], 'hola mundo');
      expect(state?['personal_shards'], 120);
      expect(state?['preshards'], 3);
      expect(container.read(myProfileProvider),
          isA<AsyncData<Map<String, dynamic>?>>());
      expect(fetcher.calls, 1);
    });

    test('returns AsyncError when the fetch throws', () async {
      final fetcher =
          _StubProfileFetcher(() async => throw Exception('boom'));
      final container = ProviderContainer(
        overrides: [
          myProfileProvider.overrideWith(() => _StubProfileNotifier(fetcher)),
        ],
      );
      addTearDown(container.dispose);

      await container.read(myProfileProvider.future).catchError((_) => null);
      final asyncValue = container.read(myProfileProvider);
      expect(asyncValue, isA<AsyncError<Map<String, dynamic>?>>());
      expect(
          (asyncValue as AsyncError<Map<String, dynamic>?>).error.toString(),
          contains('boom'));
      expect(fetcher.calls, 1);
    });

    test('refresh re-runs the fetch', () async {
      final fetcher = _StubProfileFetcher(() async => const {
            'username': 'dana',
          });
      final container = ProviderContainer(
        overrides: [
          myProfileProvider.overrideWith(() => _StubProfileNotifier(fetcher)),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(myProfileProvider, (_, _) {});
      addTearDown(sub.close);

      await container.read(myProfileProvider.future);
      expect(fetcher.calls, 1);

      await container.read(myProfileProvider.notifier).refresh();
      final state = await container.read(myProfileProvider.future);
      expect(fetcher.calls, 2);
      expect(state?['username'], 'dana');
    });
  });

  group('myGroupsProvider', () {
    test('returns AsyncData with the group list on success', () async {
      final fetcher = _StubGroupsFetcher(() async => const [
            {'id': 'g1', 'name': 'Fiesta Club', 'group_shards': 42},
          ]);
      final container = ProviderContainer(
        overrides: [
          myGroupsProvider.overrideWith(() => _StubGroupsNotifier(fetcher)),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(myGroupsProvider.future);
      expect(state, hasLength(1));
      expect(state.first['name'], 'Fiesta Club');
      expect(container.read(myGroupsProvider),
          isA<AsyncData<List<Map<String, dynamic>>>>());
      expect(fetcher.calls, 1);
    });

    test('returns AsyncError when the fetch throws', () async {
      final fetcher =
          _StubGroupsFetcher(() async => throw Exception('grupos caidos'));
      final container = ProviderContainer(
        overrides: [
          myGroupsProvider.overrideWith(() => _StubGroupsNotifier(fetcher)),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(myGroupsProvider.future)
          .catchError((_) => const <Map<String, dynamic>>[]);
      final asyncValue = container.read(myGroupsProvider);
      expect(asyncValue, isA<AsyncError<List<Map<String, dynamic>>>>());
      expect(
          (asyncValue as AsyncError<List<Map<String, dynamic>>>).error
              .toString(),
          contains('grupos caidos'));
      expect(fetcher.calls, 1);
    });

    test('refresh re-runs the fetch', () async {
      final fetcher = _StubGroupsFetcher(() async => const [
            {'id': 'g1', 'name': 'Fiesta Club', 'group_shards': 42},
          ]);
      final container = ProviderContainer(
        overrides: [
          myGroupsProvider.overrideWith(() => _StubGroupsNotifier(fetcher)),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(myGroupsProvider, (_, _) {});
      addTearDown(sub.close);

      await container.read(myGroupsProvider.future);
      expect(fetcher.calls, 1);

      await container.read(myGroupsProvider.notifier).refresh();
      await container.read(myGroupsProvider.future);
      expect(fetcher.calls, 2);
    });
  });
}
