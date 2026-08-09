import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/secure_session_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Mocktail stand-in for `flutter_secure_storage` (SEC-11/M-33, agent I-25).
///
/// No platform channels are ever touched: the plugin is a MethodChannel
/// plugin that cannot run in the widget-test environment, so every test
/// substitutes this fake — exactly like `test/services/storage_service_test.dart`
/// mocks the same plugin for `HiveService`.
class _MockSecureStorage extends Mock implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  void setupHealthy() {
    when(() => read(key: any(named: 'key'))).thenAnswer(
      (invocation) async =>
          _store[invocation.namedArguments[#key] as String],
    );
    when(
      () => write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      _store[invocation.namedArguments[#key] as String] =
          invocation.namedArguments[#value] as String;
    });
    when(() => delete(key: any(named: 'key'))).thenAnswer(
      (invocation) async {
        _store.remove(invocation.namedArguments[#key] as String);
      },
    );
  }

  void setupBroken() {
    when(() => read(key: any(named: 'key')))
        .thenThrow(PlatformException(code: 'channel-error'));
    when(
      () => write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenThrow(PlatformException(code: 'channel-error'));
    when(() => delete(key: any(named: 'key')))
        .thenThrow(PlatformException(code: 'channel-error'));
  }
}

/// The secure-storage key under which the session string is persisted.
const _sessionKey = 'samay.auth.session';

void main() {
  late _MockSecureStorage secureStorage;

  setUp(() {
    secureStorage = _MockSecureStorage();
  });

  group('SecureSessionStorage (LocalStorage contract)', () {
    test('initialize completes without error on a healthy plugin', () async {
      secureStorage.setupHealthy();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.initialize();
    });

    test('initialize completes without error when the plugin throws',
        () async {
      secureStorage.setupBroken();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.initialize();
    });

    test('hasAccessToken is false when nothing was persisted', () async {
      secureStorage.setupHealthy();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      expect(await storage.hasAccessToken(), isFalse);
    });

    test('persistSession stores under the samay.auth.session key', () async {
      secureStorage.setupHealthy();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.persistSession('{"session":"payload"}');

      verify(
        () => secureStorage.write(
          key: _sessionKey,
          value: '{"session":"payload"}',
        ),
      ).called(1);
      expect(await storage.hasAccessToken(), isTrue);
    });

    test('accessToken returns the persisted session string', () async {
      secureStorage.setupHealthy();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.persistSession('{"access_token":"jwt"}');

      expect(await storage.accessToken(), '{"access_token":"jwt"}');
    });

    test('accessToken returns null when nothing was persisted', () async {
      secureStorage.setupHealthy();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      expect(await storage.accessToken(), isNull);
    });

    test('removePersistedSession clears the stored session', () async {
      secureStorage.setupHealthy();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.persistSession('{"access_token":"jwt"}');
      await storage.removePersistedSession();

      verify(() => secureStorage.delete(key: _sessionKey)).called(1);
      expect(await storage.hasAccessToken(), isFalse);
      expect(await storage.accessToken(), isNull);
    });

    test('persistSession overwrites a previous session', () async {
      secureStorage.setupHealthy();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.persistSession('first');
      await storage.persistSession('second');

      expect(await storage.accessToken(), 'second');
    });
  });

  group('SecurePkceStorage (GotrueAsyncStorage contract)', () {
    test('setItem stores under the prefixed samay.auth.* key', () async {
      secureStorage.setupHealthy();
      final storage = SecurePkceStorage(secureStorage: secureStorage);

      await storage.setItem(key: 'code-verifier', value: 'verifier-value');

      verify(
        () => secureStorage.write(
          key: 'samay.auth.code-verifier',
          value: 'verifier-value',
        ),
      ).called(1);
    });

    test('getItem returns the value stored via setItem', () async {
      secureStorage.setupHealthy();
      final storage = SecurePkceStorage(secureStorage: secureStorage);

      await storage.setItem(key: 'code-verifier', value: 'abc123');
      final value = await storage.getItem(key: 'code-verifier');

      expect(value, 'abc123');
      verify(
        () => secureStorage.read(key: 'samay.auth.code-verifier'),
      ).called(1);
    });

    test('getItem returns null for an unknown key', () async {
      secureStorage.setupHealthy();
      final storage = SecurePkceStorage(secureStorage: secureStorage);

      expect(await storage.getItem(key: 'missing'), isNull);
    });

    test('removeItem deletes the prefixed key', () async {
      secureStorage.setupHealthy();
      final storage = SecurePkceStorage(secureStorage: secureStorage);

      await storage.setItem(key: 'code-verifier', value: 'abc123');
      await storage.removeItem(key: 'code-verifier');

      verify(
        () => secureStorage.delete(key: 'samay.auth.code-verifier'),
      ).called(1);
      expect(await storage.getItem(key: 'code-verifier'), isNull);
    });
  });

  group('graceful fallback when the plugin throws (never crash)', () {
    test('reads fall back to in-memory and report no session', () async {
      secureStorage.setupBroken();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.initialize();

      expect(await storage.hasAccessToken(), isFalse);
      expect(await storage.accessToken(), isNull);
    });

    test('persistSession survives a broken plugin (in-memory) and stays '
        'readable for the app session', () async {
      secureStorage.setupBroken();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.persistSession('{"access_token":"jwt"}');

      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), '{"access_token":"jwt"}');
    });

    test('removePersistedSession survives a broken plugin', () async {
      secureStorage.setupBroken();
      final storage = SecureSessionStorage(secureStorage: secureStorage);

      await storage.persistSession('{"access_token":"jwt"}');
      await storage.removePersistedSession();

      expect(await storage.hasAccessToken(), isFalse);
      expect(await storage.accessToken(), isNull);
    });

    test('PKCE storage survives a broken plugin (in-memory)', () async {
      secureStorage.setupBroken();
      final storage = SecurePkceStorage(secureStorage: secureStorage);

      await storage.setItem(key: 'code-verifier', value: 'abc123');

      expect(await storage.getItem(key: 'code-verifier'), 'abc123');
      await storage.removeItem(key: 'code-verifier');
      expect(await storage.getItem(key: 'code-verifier'), isNull);
    });

    test('once the fallback engages it stays engaged (one-way degradation, '
        'never an exception)', () async {
      // Simulate a plugin whose read throws on the first call (the
      // initialize() probe), then "recovers": once the fallback engages it
      // stays engaged, so every later operation is served from memory —
      // deterministic, no read-again-maybe-throws flip-flopping.
      var readCalls = 0;
      when(() => secureStorage.read(key: any(named: 'key')))
          .thenAnswer((invocation) async {
        readCalls++;
        if (readCalls == 1) {
          throw PlatformException(code: 'channel-error');
        }
        return null;
      });
      when(
        () => secureStorage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((_) async {});
      when(() => secureStorage.delete(key: any(named: 'key')))
          .thenAnswer((_) async {});

      final storage = SecureSessionStorage(secureStorage: secureStorage);
      await storage.initialize();
      await storage.persistSession('{"access_token":"jwt"}');

      // The write went to memory (the fallback was already engaged), and the
      // recovered plugin read is ignored.
      verifyNever(() => secureStorage.write(
          key: _sessionKey, value: any(named: 'value')));
      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), '{"access_token":"jwt"}');
    });
  });
}
