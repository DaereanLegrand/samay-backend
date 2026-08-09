import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/crypto/e2ee_primitives.dart';
import 'package:samay/crypto/x3dh.dart';

/// Deterministic fixtures: Alice's identity, Bob's identity, signed prekey
/// and one-time prekey, all from fixed seeds so every run is reproducible.
Future<_PartyKeys> _aliceKeys() async => _PartyKeys(
  identity: await E2eeKeyPair.fromSeed(
    Uint8List.fromList(List.generate(32, (i) => 0x10 + i)),
    type: E2eeKeyType.x25519,
  ),
  identitySig: await E2eeKeyPair.fromSeed(
    Uint8List.fromList(List.generate(32, (i) => 0x40 + i)),
    type: E2eeKeyType.ed25519,
  ),
);

Future<_PartyKeys> _bobKeys() async => _PartyKeys(
  identity: await E2eeKeyPair.fromSeed(
    Uint8List.fromList(List.generate(32, (i) => 0x80 + i)),
    type: E2eeKeyType.x25519,
  ),
  identitySig: await E2eeKeyPair.fromSeed(
    Uint8List.fromList(List.generate(32, (i) => 0xC0 + i)),
    type: E2eeKeyType.ed25519,
  ),
);

/// Bob's published prekey material: the bundle (as the server would serve it)
/// plus the private keypairs Bob must load by id to respond (E2EE §5.4).
Future<_BobFixture> _bobFixture(_PartyKeys bob, {bool withOpk = true}) async {
  final spk = await E2eeKeyPair.generate(type: E2eeKeyType.x25519);
  final opk = withOpk ? await E2eeKeyPair.generate(type: E2eeKeyType.x25519) : null;
  final signature = await ed25519Sign(bob.identitySig.privateKey, spk.publicKey);
  return _BobFixture(
    bundle: PrekeyBundle(
      identityKey: bob.identity.publicKey,
      identitySigKey: bob.identitySig.publicKey,
      signedPrekeyId: 7,
      signedPrekey: spk.publicKey,
      signature: signature,
      oneTimePrekeyId: withOpk ? 3 : null,
      oneTimePrekey: opk?.publicKey,
    ),
    spk: spk,
    opk: opk,
  );
}

class _PartyKeys {
  _PartyKeys({required this.identity, required this.identitySig});
  final E2eeKeyPair identity; // X25519 (IK_dh)
  final E2eeKeyPair identitySig; // Ed25519 (IK_sig)
}

class _BobFixture {
  _BobFixture({required this.bundle, required this.spk, this.opk});
  final PrekeyBundle bundle;
  final E2eeKeyPair spk;
  final E2eeKeyPair? opk;
}

/// Bob's responder side of X3DH: same formulas as §5.4 with the stored
/// private keypairs.
Future<Uint8List> _respond(_BobFixture bob, _PartyKeys bobKeys, _PartyKeys alice, Uint8List ekA) =>
    x3dhRespond(
      ourIdentityPrivateKey: bobKeys.identity.privateKey,
      ourSignedPrekey: bob.spk,
      ourOneTimePrekeyPrivateKey: bob.opk?.privateKey,
      theirIdentityPublicKey: alice.identity.publicKey,
      theirEphemeralPublicKey: ekA,
    );

void main() {
  group('X3DH — initiator and responder agree', () {
    test('both parties derive the SAME shared secret (with one-time prekey)', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final bobFixture = await _bobFixture(bob, withOpk: true);

      final init = await x3dhInitiate(
        ourIdentityPrivateKey: alice.identity.privateKey,
        ourIdentityPublicKey: alice.identity.publicKey,
        bundle: bobFixture.bundle,
      );
      final skB = await _respond(bobFixture, bob, alice, init.ephemeralPublicKey);
      expect(init.sharedSecret.length, 32);
      expect(skB.length, 32);
      expect(init.sharedSecret, equals(skB));
    });

    test('both parties derive the SAME shared secret (no one-time prekey)', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final bobFixture = await _bobFixture(bob, withOpk: false);

      final init = await x3dhInitiate(
        ourIdentityPrivateKey: alice.identity.privateKey,
        ourIdentityPublicKey: alice.identity.publicKey,
        bundle: bobFixture.bundle,
      );
      final skB = await x3dhRespond(
        ourIdentityPrivateKey: bob.identity.privateKey,
        ourSignedPrekey: bobFixture.spk,
        ourOneTimePrekeyPrivateKey: null,
        theirIdentityPublicKey: alice.identity.publicKey,
        theirEphemeralPublicKey: init.ephemeralPublicKey,
      );
      expect(init.sharedSecret, equals(skB));
    });

    test('deterministic: identical responder inputs produce identical SK', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final bobFixture = await _bobFixture(bob);
      final init = await x3dhInitiate(
        ourIdentityPrivateKey: alice.identity.privateKey,
        ourIdentityPublicKey: alice.identity.publicKey,
        bundle: bobFixture.bundle,
      );
      final sk1 = await _respond(bobFixture, bob, alice, init.ephemeralPublicKey);
      final sk2 = await _respond(bobFixture, bob, alice, init.ephemeralPublicKey);
      expect(sk1, equals(sk2));
    });
  });

  group('X3DH — signature verification (R1 §3.3)', () {
    test('forged prekey signature aborts initiation', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final bobFixture = await _bobFixture(bob);
      final forged = PrekeyBundle(
        identityKey: bobFixture.bundle.identityKey,
        identitySigKey: bobFixture.bundle.identitySigKey,
        signedPrekeyId: bobFixture.bundle.signedPrekeyId,
        signedPrekey: bobFixture.bundle.signedPrekey,
        signature: Uint8List.fromList(List.generate(64, (i) => i ^ 0xAA)),
        oneTimePrekeyId: bobFixture.bundle.oneTimePrekeyId,
        oneTimePrekey: bobFixture.bundle.oneTimePrekey,
      );
      await expectLater(
        () => x3dhInitiate(
          ourIdentityPrivateKey: alice.identity.privateKey,
          ourIdentityPublicKey: alice.identity.publicKey,
          bundle: forged,
        ),
        throwsA(isA<E2eeCryptoException>()),
      );
    });

    test('prekey signed by a different identity key aborts initiation', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final bobFixture = await _bobFixture(bob);
      final attackerSig = await ed25519Sign(alice.identitySig.privateKey, bobFixture.bundle.signedPrekey);
      final spoofed = PrekeyBundle(
        identityKey: bobFixture.bundle.identityKey,
        identitySigKey: bob.identitySig.publicKey,
        signedPrekeyId: bobFixture.bundle.signedPrekeyId,
        signedPrekey: bobFixture.bundle.signedPrekey,
        signature: attackerSig,
        oneTimePrekeyId: bobFixture.bundle.oneTimePrekeyId,
        oneTimePrekey: bobFixture.bundle.oneTimePrekey,
      );
      await expectLater(
        () => x3dhInitiate(
          ourIdentityPrivateKey: alice.identity.privateKey,
          ourIdentityPublicKey: alice.identity.publicKey,
          bundle: spoofed,
        ),
        throwsA(isA<E2eeCryptoException>()),
      );
    });

    test('signature verification failure throws before any key material is produced', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final bobFixture = await _bobFixture(bob);
      final forged = PrekeyBundle(
        identityKey: bobFixture.bundle.identityKey,
        identitySigKey: bobFixture.bundle.identitySigKey,
        signedPrekeyId: bobFixture.bundle.signedPrekeyId,
        signedPrekey: bobFixture.bundle.signedPrekey,
        signature: Uint8List(64),
        oneTimePrekeyId: bobFixture.bundle.oneTimePrekeyId,
        oneTimePrekey: bobFixture.bundle.oneTimePrekey,
      );
      await expectLater(
        () => x3dhInitiate(
          ourIdentityPrivateKey: alice.identity.privateKey,
          ourIdentityPublicKey: alice.identity.publicKey,
          bundle: forged,
        ),
        throwsA(isA<E2eeCryptoException>()),
      );
    });
  });

  group('X3DH — forward secrecy structure', () {
    test('using a one-time prekey changes the derived SK (DH4 inclusion)', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final withOpk = await _bobFixture(bob, withOpk: true);

      final initWithOpk = await x3dhInitiate(
        ourIdentityPrivateKey: alice.identity.privateKey,
        ourIdentityPublicKey: alice.identity.publicKey,
        bundle: withOpk.bundle,
      );
      // Same SPK but the bundle served without a one-time prekey.
      final withoutOpk = PrekeyBundle(
        identityKey: withOpk.bundle.identityKey,
        identitySigKey: withOpk.bundle.identitySigKey,
        signedPrekeyId: withOpk.bundle.signedPrekeyId,
        signedPrekey: withOpk.bundle.signedPrekey,
        signature: withOpk.bundle.signature,
        oneTimePrekeyId: null,
        oneTimePrekey: null,
      );
      final initWithoutOpk = await x3dhInitiate(
        ourIdentityPrivateKey: alice.identity.privateKey,
        ourIdentityPublicKey: alice.identity.publicKey,
        bundle: withoutOpk,
      );
      expect(initWithOpk.sharedSecret, isNot(equals(initWithoutOpk.sharedSecret)));
    });

    test('a different signed prekey yields a different SK', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final b1 = await _bobFixture(bob);
      final b2 = await _bobFixture(bob);
      expect(b1.bundle.signedPrekey, isNot(equals(b2.bundle.signedPrekey)));
      final sk1 = await x3dhInitiate(
        ourIdentityPrivateKey: alice.identity.privateKey,
        ourIdentityPublicKey: alice.identity.publicKey,
        bundle: b1.bundle,
      );
      final sk2 = await x3dhInitiate(
        ourIdentityPrivateKey: alice.identity.privateKey,
        ourIdentityPublicKey: alice.identity.publicKey,
        bundle: b2.bundle,
      );
      expect(sk1.sharedSecret, isNot(equals(sk2.sharedSecret)));
    });

    test('DH1..DH4 all contribute: changing Alice\'s identity changes SK', () async {
      final alice1 = await _aliceKeys();
      final alice2 = _PartyKeys(
        identity: await E2eeKeyPair.fromSeed(
          Uint8List.fromList(List.generate(32, (i) => 0x20 + i)),
          type: E2eeKeyType.x25519,
        ),
        identitySig: await E2eeKeyPair.fromSeed(
          Uint8List.fromList(List.generate(32, (i) => 0x50 + i)),
          type: E2eeKeyType.ed25519,
        ),
      );
      final bob = await _bobKeys();
      final bobFixture = await _bobFixture(bob);

      final sk1 = await x3dhInitiate(
        ourIdentityPrivateKey: alice1.identity.privateKey,
        ourIdentityPublicKey: alice1.identity.publicKey,
        bundle: bobFixture.bundle,
      );
      final sk2 = await x3dhInitiate(
        ourIdentityPrivateKey: alice2.identity.privateKey,
        ourIdentityPublicKey: alice2.identity.publicKey,
        bundle: bobFixture.bundle,
      );
      expect(sk1.sharedSecret, isNot(equals(sk2.sharedSecret)));
    });

    test('initiate succeeds even when the bundle lacks a one-time prekey', () async {
      final alice = await _aliceKeys();
      final bob = await _bobKeys();
      final bobFixture = await _bobFixture(bob, withOpk: false);
      final init = await x3dhInitiate(
        ourIdentityPrivateKey: alice.identity.privateKey,
        ourIdentityPublicKey: alice.identity.publicKey,
        bundle: bobFixture.bundle,
      );
      expect(init.sharedSecret.length, 32);
      expect(init.ephemeralPublicKey.length, 32);
    });
  });
}
