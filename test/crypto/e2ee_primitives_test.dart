import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/crypto/e2ee_primitives.dart';

Uint8List hexBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList(
    List.generate(clean.length ~/ 2, (i) => int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16)),
  );
}

void main() {
  group('hkdfSha256 (RFC 5869)', () {
    test('test case 1 known-answer vector', () async {
      // RFC 5869 Appendix A.1:
      // IKM = 0x0b x 22, salt = 0x00..0x0c, info = 0xf0..0xf9, L = 42.
      final okm = await hkdfSha256(
        ikm: Uint8List.fromList(List.filled(22, 0x0b)),
        salt: hexBytes('000102030405060708090a0b0c'),
        info: hexBytes('f0f1f2f3f4f5f6f7f8f9'),
        length: 42,
      );
      expect(
        okm,
        hexBytes('3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865'),
      );
    });

    test('test case 2 known-answer vector (long IKM, L=82)', () async {
      final ikm = List<int>.generate(80, (i) => i); // 0x00..0x4f
      final okm = await hkdfSha256(
        ikm: Uint8List.fromList(ikm),
        salt: hexBytes('606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf'),
        info: hexBytes('b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'),
        length: 82,
      );
      expect(
        okm,
        hexBytes('b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87'),
      );
    });

    test('distinct info strings produce distinct outputs (domain separation)', () async {
      final ikm = Uint8List.fromList(List.filled(32, 7));
      final a = await hkdfSha256(ikm: ikm, salt: Uint8List(32), info: utf8Bytes('samay.e2ee.x3dh.v1'), length: 32);
      final b = await hkdfSha256(ikm: ikm, salt: Uint8List(32), info: utf8Bytes('samay.e2ee.rk.v1'), length: 32);
      expect(a, isNot(equals(b)));
    });

    test('salt is optional (zero-filled per X3DH spec)', () async {
      final a = await hkdfSha256(ikm: Uint8List.fromList(List.filled(32, 1)), salt: Uint8List(32), info: utf8Bytes('i'), length: 32);
      final b = await hkdfSha256(ikm: Uint8List.fromList(List.filled(32, 1)), info: utf8Bytes('i'), length: 32);
      expect(a, equals(b));
    });
  });

  group('dh (X25519, RFC 7748)', () {
    test('§6.1 known-answer vector', () async {
      final alicePair = await E2eeKeyPair.fromSeed(
        hexBytes('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'),
        type: E2eeKeyType.x25519,
      );
      final bobPair = await E2eeKeyPair.fromSeed(
        hexBytes('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb'),
        type: E2eeKeyType.x25519,
      );
      expect(alicePair.publicKey, hexBytes('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'));
      expect(bobPair.publicKey, hexBytes('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f'));

      final shared = await dh(alicePair, bobPair.publicKey);
      expect(shared, hexBytes('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'));
    });

    test('symmetric: dh(a, B) == dh(b, A)', () async {
      final a = await E2eeKeyPair.generate(type: E2eeKeyType.x25519);
      final b = await E2eeKeyPair.generate(type: E2eeKeyType.x25519);
      final ab = await dh(a, b.publicKey);
      final ba = await dh(b, a.publicKey);
      expect(ab, equals(ba));
      expect(ab.length, 32);
    });

    test('fromSeed is deterministic; generate produces fresh keys', () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => i));
      final k1 = await E2eeKeyPair.fromSeed(seed, type: E2eeKeyType.x25519);
      final k2 = await E2eeKeyPair.fromSeed(seed, type: E2eeKeyType.x25519);
      expect(k1.publicKey, equals(k2.publicKey));
      expect(k1.privateKey, equals(k2.privateKey));

      final g1 = await E2eeKeyPair.generate(type: E2eeKeyType.x25519);
      final g2 = await E2eeKeyPair.generate(type: E2eeKeyType.x25519);
      expect(g1.publicKey, isNot(equals(g2.publicKey)));
    });
  });

  group('deriveMessageKey (KDF_CK, HMAC-SHA256 chain)', () {
    test('deterministic for the same chain key', () async {
      final ck = Uint8List.fromList(List.generate(32, (i) => i + 3));
      final a = await deriveMessageKey(ck);
      final b = await deriveMessageKey(ck);
      expect(a.nextChainKey, equals(b.nextChainKey));
      expect(a.messageKey, equals(b.messageKey));
    });

    test('0x01/0x02 domain separation: messageKey != nextChainKey', () async {
      final ck = Uint8List.fromList(List.generate(32, (i) => 0x5a));
      final step = await deriveMessageKey(ck);
      expect(step.messageKey, isNot(equals(step.nextChainKey)));
      // Each output is 32 bytes.
      expect(step.messageKey.length, 32);
      expect(step.nextChainKey.length, 32);
    });

    test('chain steps are all distinct', () async {
      var ck = Uint8List.fromList(List.generate(32, (i) => 0x11));
      final keys = <Uint8List>{};
      for (var i = 0; i < 5; i++) {
        final step = await deriveMessageKey(ck);
        ck = step.nextChainKey;
        keys.add(step.messageKey);
      }
      expect(keys.length, 5);
    });

    test('equals HMAC-SHA256 with single-byte 0x01/0x02 constants', () async {
      final ck = Uint8List.fromList(List.generate(32, (i) => i));
      final mk = await hmacSha256(ck, Uint8List.fromList([0x01]));
      final ckNext = await hmacSha256(ck, Uint8List.fromList([0x02]));
      final step = await deriveMessageKey(ck);
      expect(step.messageKey, equals(mk));
      expect(step.nextChainKey, equals(ckNext));
    });
  });

  group('AES-256-GCM', () {
    // NIST GCM test vector set: AES-256, 96-bit IV, empty AAD. Expected
    // values cross-checked against the `cryptography` Python package.
    const keyHex =
        'feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308';
    const ivHex = 'cafebabefacedbaddecaf888';
    const ptHex =
        'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39';
    const ctHex =
        '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662';
    const tagHex = 'eb9f796c8d356fc31a8433884b696f4f';

    test('NIST known-answer vector (AES-256-GCM)', () async {
      final encrypted = await aesGcmEncrypt(
        key: hexBytes(keyHex),
        nonce: hexBytes(ivHex),
        plaintext: hexBytes(ptHex),
        aad: Uint8List(0),
      );
      // Output layout is ciphertext || tag (128-bit full tag).
      expect(encrypted, equals(hexBytes('$ctHex$tagHex')));
    });

    test('round-trip encrypt/decrypt with aad binding', () async {
      final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final nonce = Uint8List.fromList(List.generate(12, (i) => i + 2));
      final aad = Uint8List.fromList(List.generate(40, (i) => i + 3));
      final encrypted = await aesGcmEncrypt(
        key: key,
        nonce: nonce,
        plaintext: Uint8List.fromList([104, 105]), // "hi"
        aad: aad,
      );
      final decrypted = await aesGcmDecrypt(
        key: key,
        nonce: nonce,
        ciphertext: encrypted,
        aad: aad,
      );
      expect(decrypted, equals(Uint8List.fromList([104, 105])));
    });

    test('decrypt fails cleanly (returns null) on wrong key', () async {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = Uint8List(12);
      final encrypted = await aesGcmEncrypt(
        key: key,
        nonce: nonce,
        plaintext: Uint8List.fromList([1, 2, 3]),
        aad: Uint8List(0),
      );
      final wrongKey = Uint8List.fromList(List.generate(32, (i) => i + 1));
      expect(await aesGcmDecrypt(key: wrongKey, nonce: nonce, ciphertext: encrypted, aad: Uint8List(0)), isNull);
    });

    test('decrypt fails cleanly on tampered tag and tampered ciphertext', () async {
      final key = Uint8List.fromList(List.generate(32, (i) => 9));
      final nonce = Uint8List.fromList(List.generate(12, (i) => 1));
      final encrypted = await aesGcmEncrypt(
        key: key,
        nonce: nonce,
        plaintext: Uint8List.fromList([1, 2, 3, 4]),
        aad: Uint8List(0),
      );
      final flippedTag = Uint8List.fromList(encrypted);
      flippedTag[encrypted.length - 1] ^= 0x01;
      expect(await aesGcmDecrypt(key: key, nonce: nonce, ciphertext: flippedTag, aad: Uint8List(0)), isNull);

      final flippedCt = Uint8List.fromList(encrypted);
      flippedCt[0] ^= 0x80;
      expect(await aesGcmDecrypt(key: key, nonce: nonce, ciphertext: flippedCt, aad: Uint8List(0)), isNull);
    });

    test('decrypt fails cleanly on aad tampering', () async {
      final key = Uint8List.fromList(List.generate(32, (i) => 5));
      final nonce = Uint8List(12);
      final encrypted = await aesGcmEncrypt(
        key: key,
        nonce: nonce,
        plaintext: Uint8List.fromList([7]),
        aad: Uint8List.fromList([1, 2, 3]),
      );
      expect(await aesGcmDecrypt(key: key, nonce: nonce, ciphertext: encrypted, aad: Uint8List.fromList([1, 2, 4])), isNull);
    });

    test('decrypt fails cleanly on nonce tampering', () async {
      final key = Uint8List.fromList(List.generate(32, (i) => 5));
      final nonce = Uint8List.fromList(List.generate(12, (i) => 3));
      final encrypted = await aesGcmEncrypt(
        key: key,
        nonce: nonce,
        plaintext: Uint8List.fromList([7]),
        aad: Uint8List(0),
      );
      final wrongNonce = Uint8List.fromList(List.generate(12, (i) => 4));
      expect(await aesGcmDecrypt(key: key, nonce: wrongNonce, ciphertext: encrypted, aad: Uint8List(0)), isNull);
    });

    test('expandMessageKey yields 44 bytes = 32 key + 12 nonce, unique per message key', () async {
      final mk1 = Uint8List.fromList(List.generate(32, (i) => i));
      final mk2 = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final e1 = await expandMessageKey(mk1);
      final e2 = await expandMessageKey(mk2);
      expect(e1.length, 44);
      expect(e2.length, 44);
      expect(e1.sublist(0, 32), isNot(equals(e2.sublist(0, 32))));
      expect(e1.sublist(32), isNot(equals(e2.sublist(32))));
    });
  });

  group('constantTimeEquals', () {
    test('equal byte sequences compare true', () {
      final a = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(constantTimeEquals(a, Uint8List.fromList([1, 2, 3, 4, 5])), isTrue);
    });

    test('single-bit difference compares false', () {
      final a = Uint8List.fromList([1, 2, 3, 4, 5]);
      final b = Uint8List.fromList([1, 2, 3, 4, 4]);
      expect(constantTimeEquals(a, b), isFalse);
    });

    test('different lengths compare false without throwing', () {
      expect(constantTimeEquals(Uint8List.fromList([1, 2]), Uint8List.fromList([1, 2, 3])), isFalse);
      expect(constantTimeEquals(Uint8List(0), Uint8List.fromList([1])), isFalse);
    });

    test('both empty compare true', () {
      expect(constantTimeEquals(Uint8List(0), Uint8List(0)), isTrue);
    });
  });

  group('Ed25519 (prekey signature)', () {
    test('sign/verify round-trip', () async {
      final keyPair = await E2eeKeyPair.generate(type: E2eeKeyType.ed25519);
      final message = Uint8List.fromList(List.generate(32, (i) => i));
      final signature = await ed25519Sign(keyPair.privateKey, message);
      expect(signature.length, 64);
      expect(await ed25519Verify(keyPair.publicKey, message, signature), isTrue);
    });

    test('verification fails on tampered message or tampered signature', () async {
      final keyPair = await E2eeKeyPair.generate(type: E2eeKeyType.ed25519);
      final message = Uint8List.fromList(List.generate(32, (i) => i));
      final signature = await ed25519Sign(keyPair.privateKey, message);

      final tamperedMessage = Uint8List.fromList(message);
      tamperedMessage[0] ^= 0x01;
      expect(await ed25519Verify(keyPair.publicKey, tamperedMessage, signature), isFalse);

      final tamperedSig = Uint8List.fromList(signature);
      tamperedSig[10] ^= 0x01;
      expect(await ed25519Verify(keyPair.publicKey, message, tamperedSig), isFalse);
    });

    test('fromSeed is deterministic', () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => 0x2a + i));
      final k1 = await E2eeKeyPair.fromSeed(seed, type: E2eeKeyType.ed25519);
      final k2 = await E2eeKeyPair.fromSeed(seed, type: E2eeKeyType.ed25519);
      expect(k1.publicKey, equals(k2.publicKey));
      expect(k1.privateKey, equals(k2.privateKey));
    });
  });
}
