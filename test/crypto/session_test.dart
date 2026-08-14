import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/crypto/codec.dart';
import 'package:samay/crypto/constants.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/crypto/e2ee_primitives.dart';
import 'package:samay/crypto/envelope.dart';
import 'package:samay/crypto/interfaces.dart';
import 'package:samay/crypto/session.dart';
import 'package:samay/crypto/x3dh.dart';

const _chatId = 'chat-1';

/// Server-side prekey registry (the fake Supabase of E2EE §9.3): each user
/// publishes one bundle; fetching marks the one-time prekey consumed.
class _PrekeyRegistry {
  final Map<String, PrekeyBundle> bundles = {};
  final Map<String, E2eeKeyStore> stores = {};
  bool drainOpks = false;
}

class _FakePrekeyServer implements E2eePrekeyService {
  _FakePrekeyServer({
    required this.userId,
    required this.store,
    required this.registry,
  });

  final String userId;
  final E2eeKeyStore store;
  final _PrekeyRegistry registry;

  /// Server-side consumed OPKs (the RPC marks `used_at` at fetch time,
  /// §9.3 — a re-fetch must serve a fresh OPK).
  final Set<int> _consumed = {};

  @override
  Future<void> publishAll() async {
    final identity = await store.loadOrCreateIdentity();
    final spk = await store.currentSignedPrekey();
    final opks = await store.generateOneTimePrekeys(10);
    final opk = opks.first;
    registry.stores[userId] = store;
    registry.bundles[userId] = PrekeyBundle(
      identityKey: identity.ikDhPublic,
      identitySigKey: identity.ikSigPublic,
      signedPrekeyId: spk.id,
      signedPrekey: spk.keyPair.publicKey,
      signature: spk.signature,
      oneTimePrekeyId: opk.id,
      oneTimePrekey: opk.keyPair.publicKey,
    );
  }

  @override
  Future<PrekeyBundle?> fetchBundle(String peerUserId) async {
    var bundle = registry.bundles[peerUserId];
    if (bundle == null) return null;
    if (bundle.oneTimePrekeyId != null &&
        _consumed.contains(bundle.oneTimePrekeyId)) {
      // The owner's store holds the private keys — the server must generate
      // into the OWNER's store, not the fetcher's (§9.3 semantics).
      final ownerStore = registry.stores[peerUserId];
      if (ownerStore == null) return null;
      final opks = await ownerStore.generateOneTimePrekeys(1);
      bundle = PrekeyBundle(
        identityKey: bundle.identityKey,
        identitySigKey: bundle.identitySigKey,
        signedPrekeyId: bundle.signedPrekeyId,
        signedPrekey: bundle.signedPrekey,
        signature: bundle.signature,
        oneTimePrekeyId: opks.first.id,
        oneTimePrekey: opks.first.keyPair.publicKey,
      );
      registry.bundles[peerUserId] = bundle;
    }
    if (bundle.oneTimePrekeyId != null) {
      _consumed.add(bundle.oneTimePrekeyId!);
    }
    if (registry.drainOpks) {
      return PrekeyBundle(
        identityKey: bundle.identityKey,
        identitySigKey: bundle.identitySigKey,
        signedPrekeyId: bundle.signedPrekeyId,
        signedPrekey: bundle.signedPrekey,
        signature: bundle.signature,
        oneTimePrekeyId: null,
        oneTimePrekey: null,
      );
    }
    return bundle;
  }
}

class _Party {
  _Party({
    required this.userId,
    required String peerUserId,
    required this.registry,
    DateTime Function()? clock,
  }) : _peerUserId = peerUserId,
       keys = MemoryE2eeKeyStore(clock: clock),
       sessions = MemoryE2eeSessionStore(clock: clock),
       _clock = clock {
    server = _FakePrekeyServer(userId: userId, store: keys, registry: registry);
    session = restartSession();
  }

  final String userId;
  final String _peerUserId;
  final _PrekeyRegistry registry;
  final DateTime Function()? _clock;
  final MemoryE2eeKeyStore keys;
  final MemoryE2eeSessionStore sessions;
  late final _FakePrekeyServer server;
  late final E2eeSession session;

  /// A brand-new session object over the SAME key/session stores — the
  /// "app restart" simulation (§7.3 resumption).
  E2eeSession restartSession() => E2eeSession(
    chatId: _chatId,
    peerUserId: _peerUserId,
    keyStore: keys,
    sessionStore: sessions,
    prekeyService: server,
    clock: _clock,
  );
}

SamayEnvelope _parseEnvelope(String b64) {
  final parsed = SamayEnvelope.tryParse(base64UrlNoPadDecode(b64)!);
  expect(parsed, isNotNull, reason: 'envelope must parse');
  return parsed!;
}

void main() {
  late _PrekeyRegistry registry;

  setUp(() {
    registry = _PrekeyRegistry();
  });

  group('two-party end-to-end', () {
    test('A→B init envelope, B responds, ratchet envelopes follow (I1 core)', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      // A's first message is the X3DH init envelope (type 0x01).
      final env1 = await a.session.encryptText('hola bob');
      final parsed1 = _parseEnvelope(env1);
      expect(parsed1.type, e2eeEnvelopeTypeInit);
      expect(parsed1.senderIkDh, equals((await a.keys.loadOrCreateIdentity()).ikDhPublic));

      // B decrypts it and can now respond (type 0x02).
      expect(await b.session.decryptEnvelope(env1), 'hola bob');
      final env2 = await b.session.encryptText('hola alice');
      expect(_parseEnvelope(env2).type, e2eeEnvelopeTypeRatchet);
      expect(await a.session.decryptEnvelope(env2), 'hola alice');

      // A full exchange with DH ratchet turns.
      for (var i = 0; i < 20; i++) {
        final out = await a.session.encryptText('msg A$i');
        expect(_parseEnvelope(out).type, e2eeEnvelopeTypeRatchet);
        expect(await b.session.decryptEnvelope(out), 'msg A$i');

        final back = await b.session.encryptText('msg B$i');
        expect(await a.session.decryptEnvelope(back), 'msg B$i');
      }
      // Sessions were persisted after every operation.
      expect(await a.sessions.loadSession(_chatId), isNotNull);
      expect(await b.sessions.loadSession(_chatId), isNotNull);
    });

    test('restart from serialized session: both sides resume mid-flow', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final env1 = await a.session.encryptText('primera');
      await b.session.decryptEnvelope(env1);
      final env2 = await b.session.encryptText('segunda');
      await a.session.decryptEnvelope(env2);

      // "Restart": brand-new session objects over the same stores.
      final a2 = a.restartSession();
      final b2 = b.restartSession();

      final env3 = await a2.encryptText('tercera');
      expect(await b2.decryptEnvelope(env3), 'tercera');
      final env4 = await b2.encryptText('cuarta');
      expect(await a2.decryptEnvelope(env4), 'cuarta');
    });

    test('wipe() deletes the session; further decrypts return null', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final env1 = await a.session.encryptText('hola');
      await b.session.decryptEnvelope(env1);

      a.session.wipe();
      expect(await a.sessions.loadSession(_chatId), isNull);

      final env2 = await b.session.encryptText('sigue');
      expect(await a.session.decryptEnvelope(env2), isNull);
      // B is unaffected: A's fresh initiate gets through to B's healthy session.
      expect(await b.session.decryptEnvelope(await a.session.encryptText('nueva sesion')), 'nueva sesion');
    });

    test('ciphertext uniqueness: same plaintext twice → different envelopes', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final e1 = await a.session.encryptText('misma');
      final e2 = await a.session.encryptText('misma');
      expect(e1, isNot(equals(e2)));
      await b.session.decryptEnvelope(e1);
      expect(await b.session.decryptEnvelope(e2), 'misma');
    });

    test('tampered envelope → null, session stays healthy', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final good1 = await a.session.encryptText('bueno');
      expect(await b.session.decryptEnvelope(good1), 'bueno');

      // Flip a bit in the ciphertext region of a fresh envelope.
      final evil = await a.session.encryptText('malo');
      final evilBytes = base64UrlNoPadDecode(evil)!;
      evilBytes[evilBytes.length - 5] ^= 0x01;
      expect(await b.session.decryptEnvelope(base64UrlNoPadEncode(evilBytes)), isNull);

      // The next legitimate message still decrypts (state preserved).
      final good2 = await a.session.encryptText('sigue');
      expect(await b.session.decryptEnvelope(good2), 'sigue');
    });

    test('garbage and truncated envelopes → null', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      await a.session.encryptText('x');
      expect(await b.session.decryptEnvelope('not-base64'), isNull);
      expect(await b.session.decryptEnvelope(base64UrlNoPadEncode(Uint8List.fromList([1, 2, 3]))), isNull);
    });

    test('encryptText fails cleanly when the peer has no published bundle', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      await a.server.publishAll(); // Bob has published nothing.
      await expectLater(
        () => a.session.encryptText('no puedo'),
        throwsA(isA<E2eeCryptoException>()),
      );
    });

    test('init works without a one-time prekey on the server', () async {
      registry.drainOpks = true;
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final env = await a.session.encryptText('sin opk');
      expect(_parseEnvelope(env).opkId, e2eeNoOpkId);
      expect(await b.session.decryptEnvelope(env), 'sin opk');
    });

    test('init envelope addressed to someone else (recipient_ik_dh mismatch) → null', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      final mallory = _Party(userId: 'mallory', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();
      await mallory.server.publishAll();

      final env = await a.session.encryptText('para bob');
      final bytes = base64UrlNoPadDecode(env)!;
      // Rewrite recipient_ik_dh to Mallory's identity key.
      final malloryIk = (await mallory.keys.loadOrCreateIdentity()).ikDhPublic;
      bytes.setRange(70, 102, malloryIk);
      final tampered = base64UrlNoPadEncode(bytes);
      // Bob drops it (delivery binding, E2EE §6.5)...
      expect(await b.session.decryptEnvelope(tampered), isNull);
      // ...and Mallory, the addressed recipient, cannot decrypt it either
      // (she does not share a session with Alice).
      expect(await mallory.session.decryptEnvelope(env), isNull);
    });

    test('ratchet envelope from an unknown sender (sender_ik_dh mismatch) → null', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final env1 = await a.session.encryptText('hola');
      await b.session.decryptEnvelope(env1);

      final mallory = _Party(userId: 'mallory', peerUserId: 'alice', registry: registry);
      await mallory.server.publishAll();
      final envM = await mallory.session.encryptText('spoof');
      // Mallory's ratchet envelope arrives at B labeled as a message in the
      // same chat: B must drop it (session identity binding, E2EE §7.1).
      expect(await b.session.decryptEnvelope(envM), isNull);
    });

    test('fingerprint is 30 bytes, symmetric and stable across restarts', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final env = await a.session.encryptText('x');
      await b.session.decryptEnvelope(env);

      final fpA = await a.session.computeFingerprint();
      final fpB = await b.session.computeFingerprint();
      expect(fpA.length, 30);
      expect(fpA, equals(fpB));

      final a2 = a.restartSession();
      expect(await a2.computeFingerprint(), equals(fpA));
    });

    test('computeFingerprint without a session throws — no X3DH side effect', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      // No session exists yet: the fingerprint MUST NOT initiate X3DH
      // (no session minted, no OPK consumed — read-only operation).
      await expectLater(
        () => a.session.computeFingerprint(),
        throwsA(isA<E2eeCryptoException>()),
      );
      expect(await a.sessions.loadSession(_chatId), isNull);

      // A later legitimate initiate still works normally.
      final env = await a.session.encryptText('hola');
      expect(_parseEnvelope(env).type, e2eeEnvelopeTypeInit);
      expect(await b.session.decryptEnvelope(env), 'hola');
    });
  });

  group('session lifecycle', () {
    test('peerIdentityChanged detects reinstall (new identity published)', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final env = await a.session.encryptText('hola');
      await b.session.decryptEnvelope(env);

      expect(await a.session.peerIdentityChanged('bob'), isFalse);

      // Bob reinstalls: fresh device identity, republishes.
      final b2 = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await b2.server.publishAll();
      expect(await a.session.peerIdentityChanged('bob'), isTrue);
    });

    test('peerIdentityChanged with no session yet → false', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      await a.server.publishAll();
      expect(await a.session.peerIdentityChanged('bob'), isFalse);
    });

    test('simultaneous initiation: last-processed-wins, inactive session converges (Sesame §3.2/§3.4)', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      // Both sides initiate at the same time.
      final initA = await a.session.encryptText('init de A');
      final initB = await b.session.encryptText('init de B');
      expect(_parseEnvelope(initA).type, e2eeEnvelopeTypeInit);
      expect(_parseEnvelope(initB).type, e2eeEnvelopeTypeInit);

      // Each processes the other's init: the init envelope REPLACES the
      // locally-created session (last-processed-wins, E2EE §7.2 / D-11) and
      // the replaced session is kept as inactive (Sesame §3.2).
      expect(await b.session.decryptEnvelope(initA), 'init de A');
      expect(await a.session.decryptEnvelope(initB), 'init de B');

      // From now on both send ratchet envelopes (no more inits).
      expect(_parseEnvelope(await a.session.encryptText('despues A')).type, e2eeEnvelopeTypeRatchet);
      expect(_parseEnvelope(await b.session.encryptText('despues B')).type, e2eeEnvelopeTypeRatchet);

      // Sesame §3.4 convergence: A's first post-cross message is encrypted
      // under the initB family; B's active (initA family) fails to decrypt,
      // so the inactive initB-family session is tried and activated.
      final afterA = await a.session.encryptText('post A');
      expect(await b.session.decryptEnvelope(afterA), 'post A');

      // The conversation continues on the converged session.
      final back = await b.session.encryptText('post B');
      expect(await a.session.decryptEnvelope(back), 'post B');
    });

    test('replayed init envelope → null, session untouched (X3DH §4.2 blacklist)', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final init = await a.session.encryptText('hola bob');
      expect(await b.session.decryptEnvelope(init), 'hola bob');

      // The server (or an attacker) replays the identical init envelope:
      // dropped without re-delivering plaintext and without touching the
      // established session.
      expect(await b.session.decryptEnvelope(init), isNull);
      expect(await b.session.decryptEnvelope(init), isNull);

      // The active session survived the replays.
      final next = await a.session.encryptText('sigue');
      expect(await b.session.decryptEnvelope(next), 'sigue');
    });

    test('no-OPK init replay is dropped by the persisted marker (X3DH §4.2)', () async {
      registry.drainOpks = true;
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final init = await a.session.encryptText('sin opk');
      expect(_parseEnvelope(init).opkId, e2eeNoOpkId);
      expect(await b.session.decryptEnvelope(init), 'sin opk');

      // A no-OPK init is fully re-derivable — only the marker stops the
      // replay (the consumed-OPK mechanism cannot).
      expect(await b.session.decryptEnvelope(init), isNull);
      expect(await b.session.decryptEnvelope(init), isNull);

      final next = await a.session.encryptText('sigue');
      expect(await b.session.decryptEnvelope(next), 'sigue');
    });

    test('init replay is still dropped after a restart (persisted marker)', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final init = await a.session.encryptText('hola');
      expect(await b.session.decryptEnvelope(init), 'hola');

      // "Restart": a fresh session object over the same store — the marker
      // must have been persisted with the session JSON.
      final b2 = b.restartSession();
      expect(await b2.decryptEnvelope(init), isNull);

      final next = await a.session.encryptText('sigue');
      expect(await b2.decryptEnvelope(next), 'sigue');
    });

    test('a NEW init from the same sender is accepted (fresh ekA → new marker)', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final init = await a.session.encryptText('primera sesion');
      expect(await b.session.decryptEnvelope(init), 'primera sesion');

      // Alice wipes her session and re-initiates: a fresh X3DH run (new
      // ephemeral key) must NOT be mistaken for a replay of the old init.
      a.session.wipe();
      final init2 = await a.session.encryptText('segunda sesion');
      expect(_parseEnvelope(init2).type, e2eeEnvelopeTypeInit);
      expect(_parseEnvelope(init2).ekA, isNot(equals(_parseEnvelope(init).ekA)));
      expect(await b.session.decryptEnvelope(init2), 'segunda sesion');
    });

    test('retired sessions expire after 30 days and can no longer decrypt (Sesame MAXLATENCY)', () async {
      var now = DateTime.utc(2026, 8, 9);
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry, clock: () => now);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry, clock: () => now);
      await a.server.publishAll();
      await b.server.publishAll();

      // Crossed init: B retires its initiator session when processing initA.
      final initA = await a.session.encryptText('init de A');
      final initB = await b.session.encryptText('init de B');
      await b.session.decryptEnvelope(initA);
      await a.session.decryptEnvelope(initB);

      // 31 days later the retired session is gone: A's post-cross ratchet
      // message (initB family) fails on B's active session and the retired
      // initB-family session is past its 30-day retention → dropped.
      now = now.add(const Duration(days: 31));
      final late = await a.session.encryptText('tarde');
      expect(await b.session.decryptEnvelope(late), isNull);
    });

    test('session JSON persists the init marker and retired sessions', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final initA = await a.session.encryptText('init de A');
      final initB = await b.session.encryptText('init de B');
      await b.session.decryptEnvelope(initA);
      await a.session.decryptEnvelope(initB);

      // Both sides carry a marker (each processed an init) and one retired
      // session (their own crossed-init session, moved to inactive).
      final aJson = jsonDecode((await a.sessions.loadSession(_chatId))!) as Map<String, dynamic>;
      final bJson = jsonDecode((await b.sessions.loadSession(_chatId))!) as Map<String, dynamic>;
      for (final json in [aJson, bJson]) {
        expect(json['last_init_marker'], isA<String>());
        final retired = json['retired_sessions'] as List<dynamic>;
        expect(retired, hasLength(1));
        final entry = Map<String, dynamic>.from(retired.first as Map);
        expect(entry['retired_at'], isA<String>());
        expect(entry['peer_ik_dh'], isA<String>());
        expect(entry['ratchet'], isA<Map>());
      }

      // Restart: the marker and retired session survive, so the replay stays
      // dropped and the convergence path still works.
      final a2 = a.restartSession();
      final b2 = b.restartSession();
      expect(await b2.decryptEnvelope(initA), isNull);
      final after = await a2.encryptText('despues');
      expect(await b2.decryptEnvelope(after), 'despues');
    });

    test('expired session (90 days idle) is not loaded and decrypts fail', () async {
      var now = DateTime.utc(2026, 8, 9);
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry, clock: () => now);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry, clock: () => now);
      await a.server.publishAll();
      await b.server.publishAll();

      final env = await a.session.encryptText('hola');
      expect(await b.session.decryptEnvelope(env), 'hola');

      // 91 days pass with no activity.
      now = now.add(const Duration(days: 91));
      final envLate = await a.session.encryptText('tarde');
      expect(await b.session.decryptEnvelope(envLate), isNull);
      expect(await b.sessions.loadSession(_chatId), isNull);
    });

    test('session JSON contains the §8.3 fields and round-trips through storage', () async {
      final a = _Party(userId: 'alice', peerUserId: 'bob', registry: registry);
      final b = _Party(userId: 'bob', peerUserId: 'alice', registry: registry);
      await a.server.publishAll();
      await b.server.publishAll();

      final env = await a.session.encryptText('hola');
      await b.session.decryptEnvelope(env);
      final env2 = await b.session.encryptText('respuesta');
      await a.session.decryptEnvelope(env2);

      final jsonText = (await a.sessions.loadSession(_chatId))!;
      final json = jsonDecode(jsonText) as Map<String, dynamic>;
      expect(json['version'], 1);
      expect(json['chat_id'], _chatId);
      expect(json['role'], 'initiator');
      expect(json['peer_ik_dh'], isA<String>());
      expect(json['rk'], isA<String>());
      expect(json['cks'], isA<String>());
      expect(json['ns'], isA<int>());
      expect(json['skipped'], isA<List<dynamic>>());
      expect(json['has_sent_init'], isTrue);
      expect(json['created_at'], isA<String>());
      expect(json['last_used_at'], isA<String>());
    });
  });
}
