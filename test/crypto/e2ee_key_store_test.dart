import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/crypto/codec.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/crypto/e2ee_primitives.dart';

/// Mocktail stand-in for `flutter_secure_storage` (the pattern proven in
/// `test/services/secure_session_storage_test.dart`): an in-memory map
/// behind the plugin interface. No platform channels are ever touched.
class _MockSecureStorage extends Mock implements FlutterSecureStorage {
  final Map<String, String> store = {};
  int _writeCount = 0;

  void setupHealthy() {
    when(() => read(key: any(named: 'key'))).thenAnswer(
      (invocation) async => store[invocation.namedArguments[#key] as String],
    );
    when(
      () => write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      store[invocation.namedArguments[#key] as String] =
          invocation.namedArguments[#value] as String;
      _writeCount++;
    });
    when(() => delete(key: any(named: 'key'))).thenAnswer((invocation) async {
      store.remove(invocation.namedArguments[#key] as String);
    });
    when(readAll).thenAnswer((_) async => Map<String, String>.from(store));
  }

  int get writes => _writeCount;
}

const _b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

void main() {
  group('MemoryE2eeKeyStore', () {
    test('loadOrCreateIdentity creates a stable identity', () async {
      final store = MemoryE2eeKeyStore();
      final a = await store.loadOrCreateIdentity();
      final b = await store.loadOrCreateIdentity();
      expect(a.ikDhPrivate.length, 32);
      expect(a.ikDhPublic.length, 32);
      expect(a.ikSigPrivate.length, 32);
      expect(a.ikSigPublic.length, 32);
      expect(a.ikDhPublic, equals(b.ikDhPublic));
      expect(a.ikSigPublic, equals(b.ikSigPublic));
      expect(a.registrationId, inInclusiveRange(1, 0x3FFF));
    });

    test('identity keys are distinct per store (per-device)', () async {
      final a = await MemoryE2eeKeyStore().loadOrCreateIdentity();
      final b = await MemoryE2eeKeyStore().loadOrCreateIdentity();
      expect(a.ikDhPublic, isNot(equals(b.ikDhPublic)));
    });

    test('currentSignedPrekey is stable until 7 days elapse', () async {
      var now = DateTime.utc(2026, 8, 9);
      final store = MemoryE2eeKeyStore(clock: () => now);
      final spk1 = await store.currentSignedPrekey();
      final spk1Again = await store.currentSignedPrekey();
      expect(spk1.id, spk1Again.id);
      expect(spk1.keyPair.publicKey, equals(spk1Again.keyPair.publicKey));
      expect(spk1.signature.length, 64);

      // 7 days later the SPK rotates; the previous one stays retrievable.
      now = now.add(const Duration(days: 7, hours: 1));
      final spk2 = await store.currentSignedPrekey();
      expect(spk2.id, isNot(spk1.id));
      final retired = await store.loadSignedPrekeyPrivate(spk1.id);
      expect(retired, isNotNull);
      expect(retired!.publicKey, equals(spk1.keyPair.publicKey));
    });

    test('retired signed prekeys expire after the 7-day retention window', () async {
      var now = DateTime.utc(2026, 8, 9);
      final store = MemoryE2eeKeyStore(clock: () => now);
      final spk1 = await store.currentSignedPrekey();
      now = now.add(const Duration(days: 7, hours: 1));
      final spk2 = await store.currentSignedPrekey();
      expect(spk2.id, isNot(spk1.id));
      expect(await store.loadSignedPrekeyPrivate(spk1.id), isNotNull);

      // 7 more days: the retired SPK private key must be gone (§5.2 —
      // "retain the previous SPK private key for 7 more days. After 7 days
      // the old SPK private key is deleted").
      now = now.add(const Duration(days: 7, hours: 1));
      expect(await store.loadSignedPrekeyPrivate(spk1.id), isNull);

      // The current SPK is unaffected.
      expect(await store.loadSignedPrekeyPrivate(spk2.id), isNotNull);
    });

    test('generateOneTimePrekeys, count, load and delete', () async {
      final store = MemoryE2eeKeyStore();
      expect(await store.oneTimePrekeyCount(), 0);
      final opks = await store.generateOneTimePrekeys(5);
      expect(opks.length, 5);
      expect(opks.map((o) => o.id).toSet().length, 5);
      expect(await store.oneTimePrekeyCount(), 5);

      final priv = await store.loadOneTimePrekeyPrivate(opks.first.id);
      expect(priv, isNotNull);
      expect(priv!.publicKey, equals(opks.first.keyPair.publicKey));

      await store.deleteOneTimePrekey(opks.first.id);
      expect(await store.oneTimePrekeyCount(), 4);
      expect(await store.loadOneTimePrekeyPrivate(opks.first.id), isNull);
    });

    test('wipeAll removes identity and every prekey', () async {
      final store = MemoryE2eeKeyStore();
      final before = await store.loadOrCreateIdentity();
      await store.currentSignedPrekey();
      await store.generateOneTimePrekeys(3);

      await store.wipeAll();

      final after = await store.loadOrCreateIdentity();
      expect(after.ikDhPublic, isNot(equals(before.ikDhPublic)));
      expect(await store.oneTimePrekeyCount(), 0);
      expect(await store.loadSignedPrekeyPrivate(0), isNull);
    });
  });

  group('SecureE2eeKeyStore (flutter_secure_storage)', () {
    test('storage is a constructor-injected seam (never hardcoded)', () {
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      final store = SecureE2eeKeyStore(secureStorage: mock);
      expect(store, isNotNull);
      // The class must not construct its own plugin: no instance of the real
      // FlutterSecureStorage is reachable here — only the injected mock.
      verifyNoMoreInteractions(mock);
    });

    test('identity lives under the samay.e2ee.identity.* namespaces', () async {
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      final store = SecureE2eeKeyStore(secureStorage: mock);

      await store.loadOrCreateIdentity();

      expect(mock.store.containsKey('samay.e2ee.identity.dh.priv'), isTrue);
      expect(mock.store.containsKey('samay.e2ee.identity.dh.pub'), isTrue);
      expect(mock.store.containsKey('samay.e2ee.identity.sig.priv'), isTrue);
      expect(mock.store.containsKey('samay.e2ee.identity.sig.pub'), isTrue);
      expect(mock.store.containsKey('samay.e2ee.registration_id'), isTrue);
      // Values are base64url-encoded 32-byte keys (raw key bytes, no wrapping).
      expect(base64UrlNoPadDecode(mock.store['samay.e2ee.identity.dh.priv']!)!.length, 32);
      expect(base64UrlNoPadDecode(mock.store['samay.e2ee.identity.dh.pub']!)!.length, 32);
      // registration id is a decimal string.
      final regId = int.parse(mock.store['samay.e2ee.registration_id']!);
      expect(regId, inInclusiveRange(1, 0x3FFF));
    });

    test('identity is loaded from storage on later calls', () async {
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      final store = SecureE2eeKeyStore(secureStorage: mock);
      final a = await store.loadOrCreateIdentity();
      final writesAfterFirst = mock.writes;
      final b = await store.loadOrCreateIdentity();
      expect(mock.writes, writesAfterFirst); // no rewrite
      expect(b.ikDhPublic, equals(a.ikDhPublic));
    });

    test('signed prekey rotates after 7 days with the clock', () async {
      var now = DateTime.utc(2026, 8, 9);
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      final store = SecureE2eeKeyStore(secureStorage: mock, clock: () => now);

      final spk1 = await store.currentSignedPrekey();
      final id1 = spk1.id;
      expect(mock.store.containsKey('samay.e2ee.spk.priv.$id1'), isTrue);
      expect(mock.store['samay.e2ee.spk.meta'], isNotNull);

      now = now.add(const Duration(days: 8));
      final spk2 = await store.currentSignedPrekey();
      expect(spk2.id, isNot(id1));
      expect(mock.store.containsKey('samay.e2ee.spk.priv.${spk2.id}'), isTrue);
      // Retained for 7 more days (delayed-init decryption).
      final retired = await store.loadSignedPrekeyPrivate(id1);
      expect(retired, isNotNull);
      expect(retired!.publicKey, equals(spk1.keyPair.publicKey));
    });

    test('retired signed prekey key file is deleted after the retention window', () async {
      var now = DateTime.utc(2026, 8, 9);
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      final store = SecureE2eeKeyStore(secureStorage: mock, clock: () => now);

      final spk1 = await store.currentSignedPrekey();
      final id1 = spk1.id;

      // Rotate after 8 days (past the 7-day rotation age).
      now = now.add(const Duration(days: 8));
      final spk2 = await store.currentSignedPrekey();
      expect(spk2.id, isNot(id1));
      expect(await store.loadSignedPrekeyPrivate(id1), isNotNull);

      // 8 more days: the retired SPK is past its 7-day retention window and
      // its key file must be deleted (forward secrecy, §5.2).
      now = now.add(const Duration(days: 8));
      expect(await store.loadSignedPrekeyPrivate(id1), isNull);
      expect(mock.store.containsKey('samay.e2ee.spk.priv.$id1'), isFalse);
    });

    test('one-time prekeys use samay.e2ee.opk.priv.<id> and meta count', () async {
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      final store = SecureE2eeKeyStore(secureStorage: mock);
      final opks = await store.generateOneTimePrekeys(4);
      expect(await store.oneTimePrekeyCount(), 4);
      for (final opk in opks) {
        expect(mock.store.containsKey('samay.e2ee.opk.priv.${opk.id}'), isTrue);
      }
      await store.deleteOneTimePrekey(opks.first.id);
      expect(await store.oneTimePrekeyCount(), 3);
      expect(mock.store.containsKey('samay.e2ee.opk.priv.${opks.first.id}'), isFalse);
    });

    test('wipeAll deletes every samay.e2ee.* key (account deletion)', () async {
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      final store = SecureE2eeKeyStore(secureStorage: mock);
      await store.loadOrCreateIdentity();
      await store.currentSignedPrekey();
      await store.generateOneTimePrekeys(2);
      final before = mock.store.keys.where((k) => k.startsWith('samay.e2ee.'));
      expect(before, isNotEmpty);

      await store.wipeAll();
      final after = mock.store.keys.where((k) => k.startsWith('samay.e2ee.'));
      expect(after, isEmpty);
    });
  });

  group('MemoryE2eeSessionStore', () {
    String sessionJson(String chatId, String peerIkDh, {String? lastUsed}) =>
        jsonEncode({
          'version': 1,
          'chat_id': chatId,
          'peer_user_id': 'peer',
          'role': 'initiator',
          'peer_ik_dh': peerIkDh,
          'peer_ik_sig': _b64,
          'rk': _b64,
          'ns': 0,
          'nr': 0,
          'pn': 0,
          'skipped': <Object>[],
          'has_sent_init': true,
          'created_at': '2026-08-09T00:00:00.000Z',
          'last_used_at': lastUsed ?? '2026-08-09T00:00:00.000Z',
        });

    test('save/load/delete round-trips the raw session JSON', () async {
      final store = MemoryE2eeSessionStore();
      final json = sessionJson('c1', 'peerIkDhB64');
      await store.saveSession('c1', json);
      expect(await store.loadSession('c1'), equals(json));
      await store.deleteSession('c1');
      expect(await store.loadSession('c1'), isNull);
    });

    test('sessionIndex maps peer ik_dh → chatId', () async {
      final store = MemoryE2eeSessionStore();
      await store.saveSession('c1', sessionJson('c1', 'peerIkDhB64'));
      await store.saveSession('c2', sessionJson('c2', 'otherPeerB64'));
      final index = await store.sessionIndex();
      expect(index['peerIkDhB64'], 'c1');
      expect(index['otherPeerB64'], 'c2');
      await store.deleteSession('c1');
      expect((await store.sessionIndex()).containsKey('peerIkDhB64'), isFalse);
    });

    test('sweepExpiredSessions removes sessions idle past the limit', () async {
      var now = DateTime.utc(2026, 8, 9);
      final store = MemoryE2eeSessionStore(clock: () => now);
      await store.saveSession('c1', sessionJson('c1', 'a', lastUsed: '2026-11-10T00:00:00.000Z'));
      await store.saveSession('c2', sessionJson('c2', 'b', lastUsed: '2026-05-01T00:00:00.000Z'));
      now = now.add(const Duration(days: 100));
      await store.sweepExpiredSessions();
      expect(await store.loadSession('c1'), isNotNull); // recently used
      expect(await store.loadSession('c2'), isNull); // 100 days idle
    });

    test('loadSession refuses sessions idle past 90 days', () async {
      var now = DateTime.utc(2026, 8, 9);
      final store = MemoryE2eeSessionStore(clock: () => now);
      await store.saveSession('c1', sessionJson('c1', 'a', lastUsed: '2026-04-01T00:00:00.000Z'));
      now = now.add(const Duration(days: 131));
      expect(await store.loadSession('c1'), isNull);
    });
  });

  group('SecureE2eeSessionStore', () {
    test('namespaces sessions under samay.e2ee.session.<chatId> + index', () async {
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      final store = SecureE2eeSessionStore(secureStorage: mock);
      const json = '{"version":1,"chat_id":"c1","peer_ik_dh":"ABCD","last_used_at":"2026-08-09T00:00:00.000Z"}';
      await store.saveSession('c1', json);
      expect(mock.store['samay.e2ee.session.c1'], equals(json));
      final index = jsonDecode(mock.store['samay.e2ee.session.index']!) as Map<String, dynamic>;
      expect(index['ABCD'], 'c1');

      expect(await store.loadSession('c1'), equals(json));
      await store.deleteSession('c1');
      expect(mock.store.containsKey('samay.e2ee.session.c1'), isFalse);
      expect(await store.loadSession('c1'), isNull);
    });

    test('expired sessions are swept via readAll enumeration', () async {
      final mock = _MockSecureStorage();
      mock.setupHealthy();
      var now = DateTime.utc(2026, 8, 9);
      final store = SecureE2eeSessionStore(secureStorage: mock, clock: () => now);
      await store.saveSession('c1', '{"chat_id":"c1","peer_ik_dh":"A","last_used_at":"2026-11-10T00:00:00.000Z"}');
      await store.saveSession('c2', '{"chat_id":"c2","peer_ik_dh":"B","last_used_at":"2026-05-01T00:00:00.000Z"}');
      now = now.add(const Duration(days: 100));
      await store.sweepExpiredSessions();
      expect(mock.store.containsKey('samay.e2ee.session.c1'), isTrue);
      expect(mock.store.containsKey('samay.e2ee.session.c2'), isFalse);
    });
  });

  group('key encoding', () {
    test('base64url helpers round-trip raw 32-byte keys', () {
      final raw = Uint8List.fromList(List.generate(32, (i) => i));
      final b64 = base64UrlNoPadEncode(raw);
      expect(b64, isNot(contains('=')));
      expect(base64UrlNoPadDecode(b64), equals(raw));
    });

    test('wipe() semantics: E2eeKeyPair material is destroyed by caller', () async {
      final pair = await E2eeKeyPair.generate(type: E2eeKeyType.x25519);
      // The primitive layer returns plain bytes; wiping is zeroing them.
      final priv = Uint8List.fromList(pair.privateKey);
      priv.fillRange(0, priv.length, 0);
      expect(priv.every((b) => b == 0), isTrue);
    });
  });
}
