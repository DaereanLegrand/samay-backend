import 'dart:async';


import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/crypto/codec.dart';
import 'package:samay/crypto/constants.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/crypto/e2ee_prekey_service.dart';
import 'package:samay/crypto/e2ee_primitives.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// SupabaseE2eePrekeyService behavioral tests: publishes identity + signed
/// prekey + one-time prekeys to `e2ee_identity_keys` (migration
/// 20260809000003), fetches peer bundles through the `fetch_prekey_bundle`
/// RPC, rotates the signed prekey, and lazily publishes on missing sessions.
///
/// Mirrors the mocktail pattern of `test/services/event_service_test.dart`:
/// the client is mocked and Postgrest chains resolve without network via
/// real builder subclasses.
class _MockSupabaseClient extends Mock implements SupabaseClient {}

class _MockGoTrueClient extends Mock implements GoTrueClient {}

class _MockQueryBuilder extends Mock implements SupabaseQueryBuilder {}

class _ResolvingFilter<T> extends PostgrestFilterBuilder<T> {
  _ResolvingFilter(Object? value)
      : _value = value,
        super(PostgrestBuilder(
          url: Uri.parse('http://localhost/fake'),
          headers: const {},
        ));

  final Object? _value;

  @override
  _ResolvingFilter<T> eq(String column, Object value) => this;

  @override
  Future<U> then<U>(
    FutureOr<U> Function(T value) onValue, {
    Function? onError,
  }) {
    return Future<U>.value(onValue(_value as T));
  }
}

const _userId = '11111111-1111-1111-1111-111111111111';
const _peerId = '22222222-2222-2222-2222-222222222222';

void main() {
  late _MockSupabaseClient client;
  late _MockGoTrueClient auth;
  late _MockQueryBuilder table;

  setUp(() {
    client = _MockSupabaseClient();
    auth = _MockGoTrueClient();
    table = _MockQueryBuilder();
    when(() => client.auth).thenReturn(auth);
    when(() => client.from(SupabaseE2eePrekeyService.tableName))
        .thenAnswer((_) => table);
    when(() => auth.currentUser).thenReturn(User.fromJson({'id': _userId}));
  });

  SupabaseE2eePrekeyService service({MemoryE2eeKeyStore? store}) =>
      SupabaseE2eePrekeyService(
        client: client,
        keyStore: store ?? MemoryE2eeKeyStore(),
      );

  group('publishAll', () {
    test('upserts the full bundle (identity + SPK + OPK batch)', () async {
      when(() => table.select()).thenAnswer(
        (_) => _ResolvingFilter<PostgrestList>(const <Map<String, dynamic>>[]),
      );
      when(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) => _ResolvingFilter<dynamic>(null));

      await service().publishAll();

      final captured = verify(() => table.upsert(captureAny(),
              onConflict: any(named: 'onConflict')))
          .captured
          .single as Map;
      expect(captured['user_id'], _userId);
      expect(captured['identity_key'], isNotEmpty);
      expect(captured['identity_sig_key'], isNotEmpty);
      expect(captured['signed_prekey_id'], isA<int>());
      expect(captured['signed_prekey'], isNotEmpty);
      expect(captured['signed_prekey_sig'], isNotEmpty);
      expect(captured['signed_prekey_expires_at'], isNotEmpty);
      final opks = captured['one_time_prekeys'] as List;
      expect(opks.length, e2eeOneTimePrekeyBatchSize);
      for (final opk in opks) {
        expect(opk['id'], isA<int>());
        expect(opk['key'], isNotEmpty);
      }
      // Private keys never leave the device: nothing published is private
      // material, so upsert payload carries public keys only.
      expect(captured.keys.any((k) => k.contains('priv')), isFalse);
    });

    test('tops up one-time prekeys only up to the batch size', () async {
      final store = MemoryE2eeKeyStore();
      final existing = <Map<String, dynamic>>[
        {
          'user_id': _userId,
          'identity_key': 'a',
          'identity_sig_key': 'b',
          'signed_prekey_id': 0,
          'signed_prekey': 'c',
          'signed_prekey_sig': 'd',
          'signed_prekey_expires_at': DateTime.now().toIso8601String(),
          'one_time_prekeys': List.generate(90, (i) => {'id': i, 'key': 'k$i'}),
          'consumed_one_time_prekeys': const [],
        },
      ];
      when(() => table.select()).thenAnswer(
        (_) => _ResolvingFilter<PostgrestList>(existing),
      );
      when(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) => _ResolvingFilter<dynamic>(null));

      await service(store: store).publishAll();

      final captured = verify(() => table.upsert(captureAny(),
              onConflict: any(named: 'onConflict')))
          .captured
          .single as Map;
      final opks = captured['one_time_prekeys'] as List;
      expect(opks.length, e2eeOneTimePrekeyBatchSize); // 90 + 10 top-up
      expect(opks.first['key'], 'k0'); // existing keys preserved
    });

    test('rotates the signed prekey when the stored one expired (> 7 days)',
        () async {
      var now = DateTime.utc(2026, 8, 1);
      final store = MemoryE2eeKeyStore(clock: () => now);
      await store.loadOrCreateIdentity();
      await store.rotateSignedPrekey();
      final spk = await store.currentSignedPrekey();
      final existing = <Map<String, dynamic>>[
        {
          'user_id': _userId,
          'identity_key': 'a',
          'identity_sig_key': 'b',
          'signed_prekey_id': spk.id,
          'signed_prekey': base64UrlNoPadEncode(spk.keyPair.publicKey),
          'signed_prekey_sig': 'd',
          'signed_prekey_expires_at': now.toIso8601String(),
          'one_time_prekeys': const [],
          'consumed_one_time_prekeys': const [],
        },
      ];
      when(() => table.select()).thenAnswer(
        (_) => _ResolvingFilter<PostgrestList>(existing),
      );
      when(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) => _ResolvingFilter<dynamic>(null));

      // 8 days pass — the SPK must rotate before the upsert.
      now = now.add(const Duration(days: 8));
      final svc = SupabaseE2eePrekeyService(
        client: client,
        keyStore: store,
        clock: () => now,
      );

      await svc.publishAll();

      final captured = verify(() => table.upsert(captureAny(),
              onConflict: any(named: 'onConflict')))
          .captured
          .single as Map;
      expect(captured['signed_prekey_id'], spk.id + 1);
      expect(captured['signed_prekey'], isNot(base64UrlNoPadEncode(spk.keyPair.publicKey)));
      final expiry = DateTime.parse(captured['signed_prekey_expires_at'] as String);
      expect(expiry.isAfter(now), isTrue);
    });

    test('throws when there is no authenticated user', () async {
      when(() => auth.currentUser).thenReturn(null);
      expect(() => service().publishAll(), throwsA(isA<Exception>()));
      verifyNever(() => table.select());
      verifyNever(() => table.upsert(any(), onConflict: any(named: 'onConflict')));
    });
  });

  group('fetchBundle', () {
    test('maps the RPC result into a PrekeyBundle (with one-time prekey)',
        () async {
      final store = MemoryE2eeKeyStore();
      final identity = await store.loadOrCreateIdentity();
      final spk = await store.currentSignedPrekey();
      final opks = await store.generateOneTimePrekeys(1);
      final rpcResult = {
        'user_id': _peerId,
        'identity_key': base64UrlNoPadEncode(identity.ikDhPublic),
        'identity_sig_key': base64UrlNoPadEncode(identity.ikSigPublic),
        'signed_prekey_id': spk.id,
        'signed_prekey': base64UrlNoPadEncode(spk.keyPair.publicKey),
        'signed_prekey_sig': base64UrlNoPadEncode(spk.signature),
        'signed_prekey_expires_at': DateTime.now().toIso8601String(),
        'one_time_prekey': {
          'id': opks.first.id,
          'key': base64UrlNoPadEncode(opks.first.keyPair.publicKey),
        },
      };
      when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
          .thenAnswer((_) => _ResolvingFilter<dynamic>(rpcResult));

      final bundle = await service().fetchBundle(_peerId);

      expect(bundle, isNotNull);
      expect(bundle!.identityKey, identity.ikDhPublic);
      expect(bundle.identitySigKey, identity.ikSigPublic);
      expect(bundle.signedPrekeyId, spk.id);
      expect(bundle.signedPrekey, spk.keyPair.publicKey);
      expect(bundle.signature, spk.signature);
      expect(bundle.oneTimePrekeyId, opks.first.id);
      expect(bundle.oneTimePrekey, opks.first.keyPair.publicKey);
      verify(() => client.rpc('fetch_prekey_bundle',
              params: {'p_user_id': _peerId}))
          .called(1);
    });

    test('serves a fresh one-time prekey on each fetch (server pops)',
        () async {
      final store = MemoryE2eeKeyStore();
      final identity = await store.loadOrCreateIdentity();
      final spk = await store.currentSignedPrekey();
      final opks = await store.generateOneTimePrekeys(3);
      final remaining = [
        {'id': opks[1].id, 'key': base64UrlNoPadEncode(opks[1].keyPair.publicKey)},
        {'id': opks[2].id, 'key': base64UrlNoPadEncode(opks[2].keyPair.publicKey)},
      ];
      when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
          .thenAnswer((_) {
        final next = remaining.removeAt(0);
        return _ResolvingFilter<dynamic>({
          'identity_key': base64UrlNoPadEncode(identity.ikDhPublic),
          'identity_sig_key': base64UrlNoPadEncode(identity.ikSigPublic),
          'signed_prekey_id': spk.id,
          'signed_prekey': base64UrlNoPadEncode(spk.keyPair.publicKey),
          'signed_prekey_sig': base64UrlNoPadEncode(spk.signature),
          'one_time_prekey': next,
        });
      });

      final svc = service();
      final first = await svc.fetchBundle(_peerId);
      final second = await svc.fetchBundle(_peerId);

      // The same OPK must never be served twice (§5.4 forward secrecy).
      expect(first!.oneTimePrekeyId, isNot(second!.oneTimePrekeyId));
    });

    test('returns null when the peer has no published keys', () async {
      when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
          .thenAnswer((_) => _ResolvingFilter<dynamic>(null));

      expect(await service().fetchBundle(_peerId), isNull);
    });

    test('returns null when the RPC result is not a bundle map', () async {
      when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
          .thenAnswer((_) => _ResolvingFilter<dynamic>('not-a-map'));

      expect(await service().fetchBundle(_peerId), isNull);
    });
  });

  group('handleMissingSession', () {
    test('publishes only when nothing is published yet, and keeps a healthy '
        'row untouched', () async {
      final store = MemoryE2eeKeyStore();
      final identity = await store.loadOrCreateIdentity();
      final identityKey = base64UrlNoPadEncode(identity.ikDhPublic);
      var published = false;
      when(() => table.select()).thenAnswer((_) {
        final v = published
            ? <Map<String, dynamic>>[
                {'user_id': _userId, 'identity_key': identityKey},
              ]
            : const <Map<String, dynamic>>[];
        return _ResolvingFilter<PostgrestList>(v);
      });
      when(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) {
        published = true;
        return _ResolvingFilter<dynamic>(null);
      });
      final svc = service(store: store);

      // First call: no own row → full publish.
      await svc.handleMissingSession();
      // Second call: a MATCHING row exists → no republish.
      await svc.handleMissingSession();
      // Single verification AFTER both calls: mocktail re-verifies the same
      // call only once — a second `.called(1)` on the same invocation fails
      // (MISTAKE block in the I-38 daily log).
      verify(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .called(1); // still only once
    });

    test('republishes when the published identity DIFFERS from the local '
        'one — stale-row recovery (Signal model, 2026-08-15)', () async {
      // The server row holds an identity that is NOT this device's (a
      // sign-out/in wipe or reinstall regenerated the local identity).
      final staleKey = base64UrlNoPadEncode((await E2eeKeyPair.generate(
        type: E2eeKeyType.x25519,
      )).publicKey);
      when(() => table.select()).thenAnswer(
        (_) => _ResolvingFilter<PostgrestList>(<Map<String, dynamic>>[
          {'user_id': _userId, 'identity_key': staleKey},
        ]),
      );
      when(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) => _ResolvingFilter<dynamic>(null));
      final store = MemoryE2eeKeyStore();
      final identity = await store.loadOrCreateIdentity();
      final svc = service(store: store);

      await svc.handleMissingSession();

      // The heal must republish the CURRENT identity over the stale row.
      final captured = verify(() => table.upsert(captureAny(),
              onConflict: any(named: 'onConflict')))
          .captured
          .single as Map;
      expect(captured['identity_key'],
          base64UrlNoPadEncode(identity.ikDhPublic));
    });
  });

  group('rotateSignedPrekey', () {
    test('forces a store rotation and republishes', () async {
      final store = MemoryE2eeKeyStore();
      final before = await store.currentSignedPrekey();
      when(() => table.select()).thenAnswer(
        (_) => _ResolvingFilter<PostgrestList>(<Map<String, dynamic>>[
          {'user_id': _userId, 'identity_key': 'x'},
        ]),
      );
      when(() => table.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) => _ResolvingFilter<dynamic>(null));

      final svc = service(store: store);
      await svc.rotateSignedPrekey();

      final after = await store.currentSignedPrekey();
      expect(after.id, before.id + 1);
      final captured = verify(() => table.upsert(captureAny(),
              onConflict: any(named: 'onConflict')))
          .captured
          .single as Map;
      expect(captured['signed_prekey_id'], after.id);
      expect(captured['signed_prekey'], base64UrlNoPadEncode(after.keyPair.publicKey));
    });
  });
}
