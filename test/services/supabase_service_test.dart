import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/auth_service.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:samay/core/services/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// In-memory storage pair (proven in test/router/app_router_test.dart): the
/// Supabase client is initialized but never contacted — requests against the
/// fake URL are the service fallback paths under test.
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

class _MockSupabaseClient extends Mock implements SupabaseClient {}

class _MockQueryBuilder extends Mock implements SupabaseQueryBuilder {}

/// A real Postgrest filter builder that resolves to [value] when awaited,
/// without any network I/O: `await` on a Postgrest builder funnels through
/// `Future.then`, which this subclass overrides. (mocktail cannot stub `then`
/// on classes that implement `Future` — see MISTAKE block in the I-11 log.)
class _ResolvingFilter<T> extends PostgrestFilterBuilder<T> {
  _ResolvingFilter(Object? value)
      : _value = value,
        super(PostgrestBuilder(
          url: Uri.parse('http://localhost/fake'),
          headers: const {},
        ));

  final Object? _value;

  @override
  Future<U> then<U>(
    FutureOr<U> Function(T value) onValue, {
    Function? onError,
  }) {
    return Future<U>.value(onValue(_value as T));
  }
}

void main() {
  setUpAll(() async {
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
  });

  group('AuthService', () {
    late _MockSupabaseClient client;

    setUp(() {
      client = _MockSupabaseClient();
    });

    AuthService service() => AuthService(
          client: client,
          config: ConfigService(client: client),
        );

    test('checkSignupEmail returns the RPC result', () async {
      final rpcResult = _ResolvingFilter<dynamic>('signup');
      when(() => client.rpc('check_signup_email',
              params: any(named: 'params')))
          .thenAnswer((_) => rpcResult);

      expect(await service().checkSignupEmail('nuevo@test.com'), 'signup');
      verify(() => client.rpc('check_signup_email',
              params: {'p_email': 'nuevo@test.com'}))
          .called(1);
    });

    test('upsertSignupTracker upserts the tracker row', () async {
      final table = _MockQueryBuilder();
      final upsertResult = _ResolvingFilter<dynamic>(null);
      when(() => client.from('signup_tracker')).thenAnswer((_) => table);
      when(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) => upsertResult);

      await service().upsertSignupTracker('a@test.com', true);

      verify(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .called(1);
    });

    test('getCurrentUser returns null when there is no session', () {
      final auth = AuthService(
        client: Supabase.instance.client,
        config: ConfigService(client: Supabase.instance.client),
      );
      expect(auth.getCurrentUser(), isNull);
    });

    test('refreshSession returns null when there is no session', () async {
      final auth = AuthService(
        client: Supabase.instance.client,
        config: ConfigService(client: Supabase.instance.client),
      );
      expect(await auth.refreshSession(), isNull);
    });

    test('userHasProfile returns false when the client is unreachable',
        () async {
      final auth = AuthService(
        client: Supabase.instance.client,
        config: ConfigService(client: Supabase.instance.client),
      );
      expect(await auth.userHasProfile('missing-user-id'), isFalse);
    });
  });

  group('ConfigService', () {
    late _MockSupabaseClient client;

    setUp(() {
      client = _MockSupabaseClient();
    });

    test('fetchAppConfig maps rows to a key -> value map', () async {
      final table = _MockQueryBuilder();
      final rows = _ResolvingFilter<List<Map<String, dynamic>>>([
        {'key': 'economy.user_signup_shards', 'value': '512'},
        {'key': 'economy.group_shard_boost_days', 'value': '21'},
      ]);
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer((_) => rows);

      final config = ConfigService(client: client);
      final map = await config.fetchAppConfig();

      expect(map['economy.user_signup_shards'], '512');
      expect(map['economy.group_shard_boost_days'], '21');
    });

    test('getSignupShardGrant reads the configured value', () async {
      final table = _MockQueryBuilder();
      final rows = _ResolvingFilter<List<Map<String, dynamic>>>([
        {'key': 'economy.user_signup_shards', 'value': '512'},
      ]);
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer((_) => rows);

      expect(await ConfigService(client: client).getSignupShardGrant(), 512);
    });

    test('getSignupShardGrant falls back to 256 on error', () async {
      final config = ConfigService(client: Supabase.instance.client);
      expect(await config.getSignupShardGrant(), 256);
    });
  });

  group('SupabaseService facade', () {
    test('exposes the decomposed services', () {
      expect(SupabaseService.instance.authService, isA<AuthService>());
      expect(SupabaseService.instance.configService, isA<ConfigService>());
      expect(SupabaseService.instance.userService, isNotNull);
      expect(SupabaseService.instance.groupService, isNotNull);
      expect(SupabaseService.instance.eventService, isNotNull);
      expect(SupabaseService.instance.chatService, isNotNull);
      expect(SupabaseService.instance.notificationService, isNotNull);
      expect(SupabaseService.instance.shardsService, isNotNull);
      expect(SupabaseService.instance.moderationService, isNotNull);
      expect(SupabaseService.instance.mediaService, isNotNull);
      expect(SupabaseService.instance.realtimeService, isNotNull);
    });

    test('keeps client and auth accessors for legacy call sites', () {
      expect(SupabaseService.instance.client, isNotNull);
      expect(SupabaseService.instance.auth, isNotNull);
    });
  });
}
