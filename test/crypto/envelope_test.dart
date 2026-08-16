import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/crypto/codec.dart';
import 'package:samay/crypto/constants.dart';
import 'package:samay/crypto/envelope.dart';

Uint8List _bytes(int length, int base) =>
    Uint8List.fromList(List.generate(length, (i) => (base + i) & 0xff));

SamayEnvelope _sampleInit() => SamayEnvelope(
  type: e2eeEnvelopeTypeInit,
  senderIkDh: _bytes(32, 0x01),
  senderIkSig: _bytes(32, 0x02),
  recipientIkDh: _bytes(32, 0x03),
  ekA: _bytes(32, 0x04),
  spkId: 7,
  opkId: e2eeNoOpkId,
  dhPub: _bytes(32, 0x05),
  pn: 0,
  n: 0,
  ciphertext: _bytes(40, 0x10), // ct‖tag
);

SamayEnvelope _sampleRatchet() => SamayEnvelope(
  type: e2eeEnvelopeTypeRatchet,
  senderIkDh: _bytes(32, 0x06),
  senderIkSig: Uint8List(32),
  dhPub: _bytes(32, 0x07),
  pn: 3,
  n: 5,
  ciphertext: _bytes(24, 0x20),
);

void main() {
  group('type 0x01 — X3DH init envelope', () {
    test('byte-exact round-trip encode/parse (186-byte fixed header)', () {
      final env = _sampleInit();
      final bytes = env.encode();
      expect(bytes.length, 186 + 40);

      final parsed = SamayEnvelope.tryParse(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, e2eeEnvelopeTypeInit);
      expect(parsed.senderIkDh, equals(env.senderIkDh));
      expect(parsed.senderIkSig, equals(env.senderIkSig));
      expect(parsed.recipientIkDh, equals(env.recipientIkDh));
      expect(parsed.ekA, equals(env.ekA));
      expect(parsed.spkId, 7);
      expect(parsed.opkId, e2eeNoOpkId);
      expect(parsed.dhPub, equals(env.dhPub));
      expect(parsed.pn, 0);
      expect(parsed.n, 0);
      expect(parsed.ciphertext, equals(env.ciphertext));
      // Re-encoding a parsed envelope is byte-identical.
      expect(parsed.encode(), equals(bytes));
    });

    test('field boundaries land on the exact offsets of §6.3', () {
      final bytes = _sampleInit().encode();
      // magic
      expect(bytes.sublist(0, 4), equals([0x53, 0x4D, 0x45, 0x32]));
      expect(bytes[4], 0x01); // version
      expect(bytes[5], 0x01); // type
      expect(bytes.sublist(6, 38), equals(_bytes(32, 0x01))); // sender_ik_dh
      expect(bytes.sublist(38, 70), equals(_bytes(32, 0x02))); // sender_ik_sig
      expect(bytes.sublist(70, 102), equals(_bytes(32, 0x03))); // recipient_ik_dh
      expect(bytes.sublist(102, 134), equals(_bytes(32, 0x04))); // ek_a
      expect(readU32be(bytes, 134), 7); // spk_id
      expect(readU32be(bytes, 138), e2eeNoOpkId); // opk_id
      expect(bytes.sublist(142, 174), equals(_bytes(32, 0x05))); // dh_pub
      expect(readU32be(bytes, 174), 0); // pn
      expect(readU32be(bytes, 178), 0); // n
      expect(readU32be(bytes, 182), 40); // ct_len
    });
  });

  group('type 0x02 — ratchet envelope', () {
    test('byte-exact round-trip encode/parse (114-byte fixed header)', () {
      final env = _sampleRatchet();
      final bytes = env.encode();
      expect(bytes.length, 114 + 24);

      final parsed = SamayEnvelope.tryParse(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, e2eeEnvelopeTypeRatchet);
      expect(bytes.length, 138);
      expect(parsed.senderIkDh, equals(env.senderIkDh));
      expect(parsed.senderIkSig, equals(Uint8List(32)));
      expect(parsed.recipientIkDh, isNull);
      expect(parsed.ekA, isNull);
      expect(parsed.spkId, isNull);
      expect(parsed.opkId, isNull);
      expect(parsed.dhPub, equals(env.dhPub));
      expect(parsed.pn, 3);
      expect(parsed.n, 5);
      expect(parsed.ciphertext, equals(env.ciphertext));
      expect(parsed.encode(), equals(bytes));
    });

    test('opk_id 0xFFFFFFFF encodes and round-trips', () {
      final env = _sampleInit();
      final parsed = SamayEnvelope.tryParse(env.encode());
      expect(parsed!.opkId, e2eeNoOpkId);
    });
  });

  group('parse rejection (E2EE §6.5)', () {
    test('truncated envelope → null', () {
      final bytes = _sampleRatchet().encode();
      expect(SamayEnvelope.tryParse(bytes.sublist(0, bytes.length - 1)), isNull);
      expect(SamayEnvelope.tryParse(bytes.sublist(0, 10)), isNull);
    });

    test('oversized ct_len → null', () {
      final bytes = _sampleRatchet().encode();
      // Flip ct_len to a huge value: length check must reject before crypto.
      bytes[108] = 0xFF;
      bytes[109] = 0xFF;
      bytes[110] = 0xFF;
      bytes[111] = 0xFF;
      expect(SamayEnvelope.tryParse(bytes), isNull);
    });

    test('garbage bytes → null', () {
      expect(SamayEnvelope.tryParse(Uint8List.fromList(List.generate(200, (i) => i))), isNull);
      expect(SamayEnvelope.tryParse(Uint8List(0)), isNull);
    });

    test('unknown magic → null', () {
      final bytes = _sampleRatchet().encode();
      bytes[0] = 0x00;
      expect(SamayEnvelope.tryParse(bytes), isNull);
    });

    test('unknown version → null (future versions rejected cleanly)', () {
      final bytes = _sampleRatchet().encode();
      bytes[4] = 0x02;
      expect(SamayEnvelope.tryParse(bytes), isNull);
    });

    test('unknown type → null', () {
      final bytes = _sampleRatchet().encode();
      // 0x03 (sender key) is a known type since ISSUE 4 — use 0x04 instead.
      bytes[5] = 0x04;
      expect(SamayEnvelope.tryParse(bytes), isNull);
      bytes[5] = 0x00;
      expect(SamayEnvelope.tryParse(bytes), isNull);
    });
  });

  group('type 0x03 — sender-key envelope (group chat, ISSUE 4)', () {
    SamayEnvelope sample() => SamayEnvelope.senderKey(
      senderIkDh: _bytes(32, 0x30),
      groupId: groupIdToBytes('3b241101-e2bb-4255-8caf-4136c566a962'),
      chainIndex: 5,
      ciphertext: _bytes(24, 0x40),
    );

    test('senderKeyHeaderSize constant = 62 bytes', () {
      expect(SamayEnvelope.senderKeyHeaderSize, 62);
    });

    test('byte-exact round-trip encode/parse', () {
      final env = sample();
      final bytes = env.encode();
      expect(bytes.length, SamayEnvelope.senderKeyHeaderSize + 24);

      final parsed = SamayEnvelope.tryParse(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, e2eeEnvelopeTypeSenderKey);
      expect(parsed.senderIkDh, equals(env.senderIkDh));
      expect(parsed.groupId, equals(env.groupId));
      expect(parsed.chainIndex, 5);
      expect(parsed.ciphertext, equals(env.ciphertext));
      expect(parsed.encode(), equals(bytes));
    });

    test('field boundaries land on the fixed offsets', () {
      final bytes = sample().encode();
      expect(bytes.sublist(0, 4), equals([0x53, 0x4D, 0x45, 0x32]));
      expect(bytes[4], 0x01); // version
      expect(bytes[5], 0x03); // type
      expect(bytes.sublist(6, 38), equals(_bytes(32, 0x30))); // sender_ik_dh
      expect(bytes.sublist(38, 54), equals(groupIdToBytes('3b241101-e2bb-4255-8caf-4136c566a962'))); // group_id
      expect(readU32be(bytes, 54), 5); // chain_index
      expect(readU32be(bytes, 58), 24); // ct_len
    });

    test('groupId encode/decode helpers round-trip', () {
      final uuid = '3b241101-e2bb-4255-8caf-4136c566a962';
      final raw = groupIdToBytes(uuid);
      expect(raw.length, e2eeEnvelopeGroupIdLength);
      expect(groupIdFromBytes(raw), uuid);
      expect(() => groupIdToBytes('not-a-uuid'), throwsArgumentError);
      expect(() => groupIdToBytes('3b241101e2bb42558caf4136c566a96'), throwsArgumentError);
    });

    test('malformed 0x03 → null (E2EE §6.5)', () {
      final bytes = sample().encode();
      expect(SamayEnvelope.tryParse(bytes.sublist(0, bytes.length - 1)), isNull);
      expect(SamayEnvelope.tryParse(bytes.sublist(0, 40)), isNull);
      // Oversized ct_len (offset 58) → rejected before any crypto.
      final oversized = Uint8List.fromList(bytes);
      oversized[58] = 0xFF;
      oversized[59] = 0xFF;
      oversized[60] = 0xFF;
      oversized[61] = 0xFF;
      expect(SamayEnvelope.tryParse(oversized), isNull);
      // Bad magic / bad version.
      final badMagic = Uint8List.fromList(bytes)..[0] = 0x00;
      expect(SamayEnvelope.tryParse(badMagic), isNull);
      final badVersion = Uint8List.fromList(bytes)..[4] = 0x02;
      expect(SamayEnvelope.tryParse(badVersion), isNull);
    });
  });

  group('base64url transport (E2EE §6.6)', () {
    test('encode/decode round-trip is padding-free and canonical', () {
      final env = _sampleInit();
      final b64 = base64UrlNoPadEncode(env.encode());
      expect(b64.contains('='), isFalse);
      // Canonical base64url alphabet (no '+' or '/').
      expect(b64.contains('+'), isFalse);
      expect(b64.contains('/'), isFalse);

      final decoded = base64UrlNoPadDecode(b64);
      expect(decoded, isNotNull);
      expect(decoded, equals(env.encode()));
    });

    test('decoding non-base64url input → null', () {
      expect(base64UrlNoPadDecode('!!!not-base64!!!'), isNull);
      expect(base64UrlNoPadDecode(''), isNotNull); // empty decodes to empty bytes
    });

    test('padded base64url input still decodes (defensive)', () {
      final bytes = _bytes(61, 0x09); // 61 % 3 == 1 → one '=' padding
      final padded = base64Url.encode(bytes);
      expect(padded.endsWith('='), isTrue);
      expect(base64UrlNoPadDecode(padded), equals(bytes));
    });
  });
}
