import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/crypto/constants.dart';
import 'package:samay/crypto/double_ratchet.dart';
import 'package:samay/crypto/e2ee_primitives.dart';

/// Fixed 128-byte AD base (mirrors the wire AD_base of the envelope spec).
final _adBase = Uint8List.fromList(List.generate(128, (i) => (i * 7 + 1) & 0xff));

/// Deterministic "now" so skipped-key timestamps are stable across runs.
final _now = DateTime.utc(2026, 8, 9);

Uint8List _message(int i) => Uint8List.fromList([0x61, 0x62, 0x63, i]); // "abc\x.."

/// Builds a matched (alice, bob, bobSpk) ratchet triple from a deterministic
/// shared secret and Bob's fixed signed-prekey pair (E2EE-ARCHITECTURE.md §4.3).
Future<(RatchetState, RatchetState, E2eeKeyPair)> _freshPair() async {
  final sk = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final bobSpk = await E2eeKeyPair.fromSeed(
    Uint8List.fromList(List.generate(32, (i) => 100 + i)),
    type: E2eeKeyType.x25519,
  );
  final alice = await ratchetInitAlice(
    rootKey: sk,
    bobRatchetKey: bobSpk.publicKey,
    now: _now,
  );
  final bob = await ratchetInitBob(
    rootKey: sk,
    bobRatchetKeyPair: bobSpk,
    now: _now,
  );
  return (alice, bob, bobSpk);
}

Future<(RatchetHeader, Uint8List)> _encrypt(RatchetState state, Uint8List pt) =>
    ratchetEncrypt(state, pt, _adBase);

Future<Uint8List> _decrypt(
  RatchetState state,
  RatchetHeader header,
  Uint8List ct, {
  DateTime? now,
}) =>
    ratchetDecrypt(state, header, ct, _adBase, now: now ?? _now);

void main() {
  group('KDF functions', () {
    test('kdfRootKey is deterministic and splits 64 bytes into rk\'|ck', () async {
      final rk = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final dhOut = Uint8List.fromList(List.generate(32, (i) => 200 + i));
      final a = await kdfRootKey(rk, dhOut);
      final b = await kdfRootKey(rk, dhOut);
      expect(a.rootKey, equals(b.rootKey));
      expect(a.chainKey, equals(b.chainKey));
      expect(a.rootKey.length, 32);
      expect(a.chainKey.length, 32);
      expect(a.rootKey, isNot(equals(a.chainKey)));
      expect(a.rootKey, isNot(equals(rk)));
      expect(a.chainKey, isNot(equals(rk)));
    });

    test('kdfRootKey output depends on both the root key and the DH output', () async {
      final rk = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final dhOut = Uint8List.fromList(List.generate(32, (i) => 200 + i));
      final base = await kdfRootKey(rk, dhOut);
      final otherRk = await kdfRootKey(Uint8List.fromList(List.generate(32, (i) => 2)), dhOut);
      final otherDh = await kdfRootKey(rk, Uint8List.fromList(List.generate(32, (i) => 3)));
      expect(base.rootKey, isNot(equals(otherRk.rootKey)));
      expect(base.chainKey, isNot(equals(otherRk.chainKey)));
      expect(base.rootKey, isNot(equals(otherDh.rootKey)));
      expect(base.chainKey, isNot(equals(otherDh.chainKey)));
    });

    test('kdfChainKey is deterministic and domain-separated (mk vs ck_next)', () async {
      final ck = Uint8List.fromList(List.generate(32, (i) => 0x44));
      final a = await kdfChainKey(ck);
      final b = await kdfChainKey(ck);
      expect(a.messageKey, equals(b.messageKey));
      expect(a.nextChainKey, equals(b.nextChainKey));
      expect(a.messageKey, isNot(equals(a.nextChainKey)));
      expect(a.messageKey.length, 32);
      expect(a.nextChainKey.length, 32);
    });

    test('kdfChainKey steps never repeat; independent walks agree', () async {
      var ck = Uint8List.fromList(List.generate(32, (i) => 0x44));
      final all = <String>[];
      for (var i = 0; i < 8; i++) {
        final step = await kdfChainKey(ck);
        all.add(step.messageKey.toString());
        ck = step.nextChainKey;
      }
      expect(all.toSet().length, all.length);

      var ck2 = Uint8List.fromList(List.generate(32, (i) => 0x44));
      final all2 = <String>[];
      for (var i = 0; i < 8; i++) {
        final step = await kdfChainKey(ck2);
        all2.add(step.messageKey.toString());
        ck2 = step.nextChainKey;
      }
      expect(all2, equals(all));
    });
  });

  group('initialization', () {
    test('ratchetInitAlice: sending chain ready, receiving chain empty', () async {
      final (alice, _, _) = await _freshPair();
      expect(alice.role, 'initiator');
      expect(alice.sendingChainKey, isNotNull);
      expect(alice.receivingChainKey, isNull);
      expect(alice.sendingMsgKeyIdx, 0);
      expect(alice.receivingMsgKeyIdx, 0);
      expect(alice.prevSendingChainLen, 0);
      expect(alice.remoteRatchetKey, isNotNull);
      expect(alice.localRatchetKey, isNotNull);
      expect(alice.skippedMessageKeys, isEmpty);
    });

    test('ratchetInitBob: DHs is Bob\'s signed prekey pair, chains empty', () async {
      final (_, bob, bobSpk) = await _freshPair();
      expect(bob.role, 'responder');
      expect(bob.localRatchetKey.privateKey, equals(bobSpk.privateKey));
      expect(bob.localRatchetKey.publicKey, equals(bobSpk.publicKey));
      expect(bob.sendingChainKey, isNull);
      expect(bob.receivingChainKey, isNull);
      expect(bob.remoteRatchetKey, isNull);
      expect(bob.skippedMessageKeys, isEmpty);
    });

    test('cannot encrypt before any sending chain exists (responder, CKs null)', () async {
      final (_, bob, _) = await _freshPair();
      await expectLater(
        () => _encrypt(bob, _message(0)),
        throwsA(isA<RatchetError>()),
      );
    });
  });

  group('ratchet round-trips', () {
    test('first message: Alice encrypts, Bob decrypts (init pattern)', () async {
      final (alice, bob, bobSpk) = await _freshPair();
      final (header, ct) = await _encrypt(alice, _message(1));
      expect(header.n, 0);
      expect(header.pn, 0);
      expect(header.dh.length, 32);

      final pt = await _decrypt(bob, header, ct);
      expect(pt, equals(_message(1)));
      // Bob's DH ratchet step set his sending chain (he can now reply).
      expect(bob.sendingChainKey, isNotNull);
      expect(bob.receivingChainKey, isNotNull);
      expect(bob.remoteRatchetKey, equals(header.dh));
      // Bob's ratchet key is no longer his signed prekey (R2 §7.1).
      expect(bob.localRatchetKey.privateKey, isNot(equals(bobSpk.privateKey)));
    });

    test('200-message ping-pong: states converge on both sides (U5)', () async {
      final (alice, bob, _) = await _freshPair();
      for (var i = 0; i < 200; i++) {
        final (h1, c1) = await _encrypt(alice, _message(i));
        expect(await _decrypt(bob, h1, c1), equals(_message(i)));

        final (h2, c2) = await _encrypt(bob, _message(1000 + i));
        expect(await _decrypt(alice, h2, c2), equals(_message(1000 + i)));
      }
      // Each reply triggers a DH ratchet step on the receiving side, so the
      // per-chain counters converge to the fixed point of the ping-pong:
      // one sealed chain of 1 message on each side (PN=1), 1 receiving
      // message key consumed, no skipped keys.
      expect(alice.sendingMsgKeyIdx, 0);
      expect(alice.receivingMsgKeyIdx, 1);
      expect(alice.prevSendingChainLen, 1);
      expect(bob.sendingMsgKeyIdx, 1);
      expect(bob.receivingMsgKeyIdx, 1);
      expect(bob.prevSendingChainLen, 1);
      expect(alice.skippedMessageKeys, isEmpty);
      expect(bob.skippedMessageKeys, isEmpty);
    });

    test('multiple DH ratchet turns with batches (U6)', () async {
      final (alice, bob, _) = await _freshPair();

      // A sends 3.
      for (var i = 0; i < 3; i++) {
        final (h, c) = await _encrypt(alice, _message(i));
        await _decrypt(bob, h, c);
      }
      // B replies 2 — B's reply carries a fresh DH key → A does a ratchet step.
      for (var i = 0; i < 2; i++) {
        final (h, c) = await _encrypt(bob, _message(10 + i));
        expect(await _decrypt(alice, h, c), equals(_message(10 + i)));
      }
      // A sends 2 more → B does a ratchet step.
      for (var i = 0; i < 2; i++) {
        final (h, c) = await _encrypt(alice, _message(20 + i));
        expect(await _decrypt(bob, h, c), equals(_message(20 + i)));
      }
      // And one more B->A turn.
      final (h, c) = await _encrypt(bob, _message(30));
      expect(await _decrypt(alice, h, c), equals(_message(30)));

      // PN tracks the sealed sending chain: A sealed 2 when processing B's
      // last message, B sealed 2 when processing A's batch.
      expect(alice.prevSendingChainLen, 2);
      expect(bob.prevSendingChainLen, 2);
    });

    test('a DH ratchet step changes rootKey, chain keys and ratchet keys', () async {
      final (alice, bob, _) = await _freshPair();
      final aliceRkBefore = Uint8List.fromList(alice.rootKey);
      final aliceCksBefore = Uint8List.fromList(alice.sendingChainKey!);
      final aliceDh0 = alice.localRatchetKey.publicKey;

      final (h1, c1) = await _encrypt(alice, _message(0));
      await _decrypt(bob, h1, c1);
      final bobRkAfterInit = Uint8List.fromList(bob.rootKey);
      expect(bobRkAfterInit, isNot(equals(aliceRkBefore))); // Bob's RK stepped from SK

      final (h2, c2) = await _encrypt(bob, _message(1));
      await _decrypt(alice, h2, c2);

      // Alice performed a DH ratchet: RK and CKs changed, new ratchet key.
      expect(alice.rootKey, isNot(equals(aliceRkBefore)));
      expect(alice.sendingChainKey, isNot(equals(aliceCksBefore)));
      expect(alice.localRatchetKey.publicKey, isNot(equals(aliceDh0)));
      // Bob's RK is unchanged by merely sending (ratchet steps on receive).
      expect(bob.rootKey, equals(bobRkAfterInit));
    });

    test('ciphertext uniqueness: same plaintext twice yields different ciphertexts', () async {
      final (alice, bob, _) = await _freshPair();
      final (h1, c1) = await _encrypt(alice, _message(7));
      final (h2, c2) = await _encrypt(alice, _message(7));
      expect(c1, isNot(equals(c2)));
      expect(h1.n, 0);
      expect(h2.n, 1);
      expect(await _decrypt(bob, h1, c1), equals(_message(7)));
      expect(await _decrypt(bob, h2, c2), equals(_message(7)));
    });
  });

  group('out-of-order and skipped keys', () {
    test('skip 5, deliver later: decrypts via MKSKIPPED (U7)', () async {
      final (alice, bob, _) = await _freshPair();
      final sent = <(RatchetHeader, Uint8List)>[];
      for (var i = 0; i < 6; i++) {
        final (h, c) = await _encrypt(alice, _message(i));
        sent.add((h, c));
      }
      // Deliver 5..2 in order, skipping 0 and 1.
      for (var i = 5; i >= 2; i--) {
        expect(await _decrypt(bob, sent[i].$1, sent[i].$2), equals(_message(i)));
      }
      expect(bob.skippedMessageKeys.length, 2);
      // Now deliver the skipped messages out of order.
      expect(await _decrypt(bob, sent[1].$1, sent[1].$2), equals(_message(1)));
      expect(await _decrypt(bob, sent[0].$1, sent[0].$2), equals(_message(0)));
      expect(bob.skippedMessageKeys, isEmpty);
    });

    test('gap larger than MAX_SKIP throws RatchetError and leaves state untouched (U8)', () async {
      final (alice, bob, _) = await _freshPair();
      final (h, c) = await _encrypt(alice, _message(0));
      await _decrypt(bob, h, c);

      RatchetHeader? farHeader;
      Uint8List? farCt;
      for (var i = 0; i < e2eeMaxSkip + 10; i++) {
        final (hx, cx) = await _encrypt(alice, _message(i + 1));
        farHeader = hx;
        farCt = cx;
      }
      final before = bob.toJson();
      await expectLater(
        () => _decrypt(bob, farHeader!, farCt!),
        throwsA(isA<RatchetError>()),
      );
      // Atomicity: Bob's state is byte-for-byte unchanged.
      expect(bob.toJson(), equals(before));
    });

    test('skipped message key is single-use: replay fails cleanly', () async {
      final (alice, bob, _) = await _freshPair();
      final sent = <(RatchetHeader, Uint8List)>[];
      for (var i = 0; i < 3; i++) {
        final (h, c) = await _encrypt(alice, _message(i));
        sent.add((h, c));
      }
      // Skip 0 and 1.
      await _decrypt(bob, sent[2].$1, sent[2].$2);
      expect(await _decrypt(bob, sent[0].$1, sent[0].$2), equals(_message(0)));
      // Replay of an already-consumed key must fail cleanly.
      await expectLater(
        () => _decrypt(bob, sent[0].$1, sent[0].$2),
        throwsA(isA<RatchetError>()),
      );
      expect(await _decrypt(bob, sent[1].$1, sent[1].$2), equals(_message(1)));
    });

    test('skipped keys are pruned by age on pruneSkippedKeys', () async {
      final (alice, bob, _) = await _freshPair();
      final sent = <(RatchetHeader, Uint8List)>[];
      for (var i = 0; i < 4; i++) {
        final (h, c) = await _encrypt(alice, _message(i));
        sent.add((h, c));
      }
      await _decrypt(bob, sent[3].$1, sent[3].$2);
      expect(bob.skippedMessageKeys.length, 3);
      // 31 days later all skipped keys are pruned (R2 §8.4 / E2EE §4.6).
      bob.pruneSkippedKeys(_now.add(const Duration(days: 31)));
      expect(bob.skippedMessageKeys, isEmpty);
    });
  });

  group('tampering and failures', () {
    test('header tampering (flip a bit in n) → auth failure, state discarded (U9)', () async {
      final (alice, bob, _) = await _freshPair();
      final (h, c) = await _encrypt(alice, _message(0));
      final tampered = RatchetHeader(dh: h.dh, pn: h.pn, n: h.n ^ 1);
      final before = bob.toJson();
      await expectLater(
        () => _decrypt(bob, tampered, c),
        throwsA(isA<RatchetError>()),
      );
      expect(bob.toJson(), equals(before));
    });

    test('header tampering (flip a bit in dh_pub) → auth failure, state discarded', () async {
      final (alice, bob, _) = await _freshPair();
      final (h, c) = await _encrypt(alice, _message(0));
      final badDh = Uint8List.fromList(h.dh);
      badDh[5] ^= 0x01;
      final before = bob.toJson();
      await expectLater(
        () => _decrypt(bob, RatchetHeader(dh: badDh, pn: h.pn, n: h.n), c),
        throwsA(isA<RatchetError>()),
      );
      expect(bob.toJson(), equals(before));
    });

    test('header tampering (flip a bit in pn) → auth failure', () async {
      final (alice, bob, _) = await _freshPair();
      final (h, c) = await _encrypt(alice, _message(0));
      await expectLater(
        () => _decrypt(bob, RatchetHeader(dh: h.dh, pn: h.pn ^ 1, n: h.n), c),
        throwsA(isA<RatchetError>()),
      );
    });

    test('ciphertext tampering → auth failure, state discarded', () async {
      final (alice, bob, _) = await _freshPair();
      final (h, c) = await _encrypt(alice, _message(0));
      final badCt = Uint8List.fromList(c);
      badCt[0] ^= 0x40;
      final before = bob.toJson();
      await expectLater(
        () => _decrypt(bob, h, badCt),
        throwsA(isA<RatchetError>()),
      );
      expect(bob.toJson(), equals(before));
    });

    test('wrong associated data → auth failure, state discarded', () async {
      final (alice, bob, _) = await _freshPair();
      final (h, c) = await _encrypt(alice, _message(0));
      final wrongAd = Uint8List.fromList(_adBase);
      wrongAd[0] ^= 0x01;
      final before = bob.toJson();
      await expectLater(
        () => ratchetDecrypt(bob, h, c, wrongAd),
        throwsA(isA<RatchetError>()),
      );
      expect(bob.toJson(), equals(before));
    });

    test('session stays healthy after a dropped (failed) message', () async {
      final (alice, bob, _) = await _freshPair();
      final (h1, c1) = await _encrypt(alice, _message(0));
      await _decrypt(bob, h1, c1);

      final (hBad, cBad) = await _encrypt(alice, _message(999));
      final badCt = Uint8List.fromList(cBad);
      badCt[2] ^= 0x02;
      await expectLater(
        () => _decrypt(bob, hBad, badCt),
        throwsA(isA<RatchetError>()),
      );

      final (h2, c2) = await _encrypt(alice, _message(1));
      expect(await _decrypt(bob, h2, c2), equals(_message(1)));
    });
  });

  group('serialization', () {
    test('state round-trips through JSON and keeps working', () async {
      final (alice, bob, _) = await _freshPair();
      final (h, c) = await _encrypt(alice, _message(0));
      await _decrypt(bob, h, c);
      final (h2, c2) = await _encrypt(bob, _message(1));
      await _decrypt(alice, h2, c2);

      final restored = RatchetState.fromJson(bob.toJson());
      expect(restored.role, bob.role);
      expect(restored.localRatchetKey.privateKey, equals(bob.localRatchetKey.privateKey));
      expect(restored.localRatchetKey.publicKey, equals(bob.localRatchetKey.publicKey));
      expect(restored.rootKey, equals(bob.rootKey));
      expect(restored.sendingChainKey, equals(bob.sendingChainKey));
      expect(restored.receivingChainKey, equals(bob.receivingChainKey));
      expect(restored.sendingMsgKeyIdx, bob.sendingMsgKeyIdx);
      expect(restored.receivingMsgKeyIdx, bob.receivingMsgKeyIdx);
      expect(restored.prevSendingChainLen, bob.prevSendingChainLen);
      expect(restored.remoteRatchetKey, equals(bob.remoteRatchetKey));
      expect(restored.skippedMessageKeys.length, bob.skippedMessageKeys.length);

      // The restored state keeps ratcheting (next message comes from Alice,
      // triggering Bob's DH ratchet with her fresh key).
      final (h3, c3) = await _encrypt(alice, _message(2));
      expect(await _decrypt(restored, h3, c3), equals(_message(2)));
      // And Bob can reply again after a restored receive.
      final (h4, c4) = await _encrypt(restored, _message(3));
      expect(await _decrypt(alice, h4, c4), equals(_message(3)));
    });
  });
}
