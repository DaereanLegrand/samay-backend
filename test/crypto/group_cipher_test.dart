import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/crypto/codec.dart';
import 'package:samay/crypto/constants.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/crypto/envelope.dart';
import 'package:samay/crypto/group_cipher.dart';
import 'package:samay/crypto/interfaces.dart';

const _groupChatId = 'chat-1';
const _otherChatId = 'chat-2';
const _groupId = '3b241101-e2bb-4255-8caf-4136c566a962';
const _otherGroupId = '99999999-8888-7777-6666-555555555555';
const _aliceId = 'alice';
const _bobId = 'bob';
const _charlieId = 'charlie';

/// One group member: its own key/session stores + the group cipher bound to
/// them (the chat layer would hold one cipher per member device).
class _Party {
  _Party({required this.id})
      : keyStore = MemoryE2eeKeyStore(),
        sessionStore = MemoryE2eeSessionStore();

  final String id;
  final E2eeKeyStore keyStore;
  final E2eeSessionStore sessionStore;
  late final GroupE2eeCipher cipher = GroupE2eeCipher(
    keyStore: keyStore,
    sessionStore: sessionStore,
  );
}

String _recordKey(String groupId, String senderUserId) =>
    '${GroupE2eeCipher.senderKeyKeyPrefix}$groupId:$senderUserId';

Future<GroupSenderKeyRecord?> _loadRecord(
  E2eeSessionStore store,
  String groupId,
  String senderUserId,
) async {
  final raw = await store.loadSession(_recordKey(groupId, senderUserId));
  return raw == null ? null : GroupSenderKeyRecord.fromJson(raw);
}

/// Distributes [senderId]'s sender-key bundle to every receiver (the chat
/// layer delivers it as the plaintext of a pairwise ratchet message).
Future<void> _distribute(
  GroupE2eeCipher sender,
  String senderId,
  List<GroupE2eeCipher> receivers, {
  String groupId = _groupId,
  String groupChatId = _groupChatId,
}) async {
  final bundle = await sender.senderKeyBundleJson(
    groupChatId: groupChatId,
    senderUserId: senderId,
    groupId: groupId,
  );
  for (final receiver in receivers) {
    await receiver.processSenderKeyBundle(
      groupChatId: groupChatId,
      senderUserId: senderId,
      groupId: groupId,
      bundleJson: bundle,
    );
  }
}

Future<String> _send(
  GroupE2eeCipher sender,
  String senderId,
  String text, {
  String groupId = _groupId,
  String groupChatId = _groupChatId,
}) =>
    sender.encrypt(
      groupChatId: groupChatId,
      senderUserId: senderId,
      groupId: groupId,
      plaintext: text,
    );

void main() {
  group('sender-key chain lifecycle', () {
    test('encrypt creates the chain and advances it (old root destroyed)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      final rootAtDistribution =
          (jsonDecode(bundle) as Map)['chain_root'] as String;

      final m0 = await _send(alice.cipher, _aliceId, 'm0');
      expect(m0, isNotEmpty);

      // The persisted chain must have advanced off the distributed root —
      // the old chain key is gone (forward secrecy).
      final record = await _loadRecord(alice.sessionStore, _groupId, _aliceId);
      expect(record, isNotNull);
      expect(record!.chainRoot, isNot(rootAtDistribution));
      expect(record.lastSentN, 1);
      expect(record.lastSeenN, -1);
      expect(record.senderUserId, _aliceId);
      expect(record.senderIkDh, isNotEmpty);
      expect(record.createdAt, isNotNull);
    });

    test('three sequential messages round-trip to a member with the bundle', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      for (var i = 0; i < 3; i++) {
        final env = await _send(alice.cipher, _aliceId, 'msg-$i');
        final result = await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: env,
        );
        expect(result.dropped, isFalse, reason: 'message $i dropped');
        expect(result.failed, isFalse, reason: 'message $i failed');
        expect(result.plaintext, 'msg-$i');
      }
    });

    test('replay drop: the same envelope twice', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final env = await _send(alice.cipher, _aliceId, 'm0');
      final first = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: env,
      );
      expect(first.plaintext, 'm0');

      final second = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: env,
      );
      expect(second.dropped, isTrue);
      expect(second.failed, isFalse);
      expect(second.plaintext, isNull);
    });

    test('out-of-order drop: gap derives through, late message is dropped', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final e0 = await _send(alice.cipher, _aliceId, 'm0');
      final e1 = await _send(alice.cipher, _aliceId, 'm1');
      final e2 = await _send(alice.cipher, _aliceId, 'm2');

      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: e0,
        )).plaintext,
        'm0',
      );
      // n=2 with a gap at n=1: the chain derives through the skipped index.
      final gap = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: e2,
      );
      expect(gap.plaintext, 'm2');
      // n=1 arrives late: n <= lastSeenN → replay/out-of-order drop.
      final lateArrival = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: e1,
      );
      expect(lateArrival.dropped, isTrue);
      expect(lateArrival.plaintext, isNull);
    });

    test('tampered ciphertext → failed (genuine undecryptable)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final env = await _send(alice.cipher, _aliceId, 'secret');
      final bytes = base64UrlNoPadDecode(env)!;
      bytes[bytes.length - 1] ^= 0x01; // flip a ciphertext byte
      final tampered = base64UrlNoPadEncode(bytes);

      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: tampered,
      );
      expect(result.failed, isTrue);
      expect(result.dropped, isFalse);
      expect(result.plaintext, isNull);
    });

    test('tampered groupId header → dropped (no record in that namespace)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final env = await _send(alice.cipher, _aliceId, 'secret');
      final bytes = base64UrlNoPadDecode(env)!;
      bytes[38] ^= 0x01; // groupId lives at offset 38..54
      final tampered = base64UrlNoPadEncode(bytes);

      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: tampered,
      );
      // The header groupId routes the record lookup into a namespace where
      // no record exists → silent protocol drop.
      expect(result.dropped, isTrue);
    });

    test('cross-group replay: header groupId swapped to another group the '
        'sender belongs to → failed (aad binding)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      const otherGroup = '99999999-8888-7777-6666-555555555555';
      // Alice has chains in BOTH groups and both reached bob's device.
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      await _distribute(
        alice.cipher,
        _aliceId,
        [bob.cipher],
        groupId: otherGroup,
      );

      final env = await _send(alice.cipher, _aliceId, 'secret');
      final bytes = base64UrlNoPadDecode(env)!;
      bytes.setRange(38, 54, groupIdToBytes(otherGroup));
      final replayed = base64UrlNoPadEncode(bytes);

      // The record exists under the other group and the identity matches,
      // but the AEAD associated data still binds the message to the group
      // it was encrypted for → genuine authentication failure.
      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: replayed,
      );
      expect(result.failed, isTrue);
      expect(result.plaintext, isNull);
    });

    test('non-0x03 or undecodable envelope → dropped', () async {
      final alice = _Party(id: _aliceId);
      final ratchet = SamayEnvelope(
        type: e2eeEnvelopeTypeRatchet,
        senderIkDh: Uint8List(32),
        senderIkSig: Uint8List(32),
        dhPub: Uint8List(32),
        pn: 0,
        n: 0,
        ciphertext: Uint8List(8),
      );
      final result = await alice.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: base64UrlNoPadEncode(ratchet.encode()),
      );
      expect(result.dropped, isTrue);
      final garbage = await alice.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: '!!!not-an-envelope!!!',
      );
      expect(garbage.dropped, isTrue);
    });
  });

  group('identity binding', () {
    test('no record for the sender → dropped (Signal NoSession)', () async {
      final alice = _Party(id: _aliceId);
      final charlie = _Party(id: _charlieId); // never processed a bundle
      await alice.cipher.encrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        plaintext: 'm0',
      );
      final env = await _send(alice.cipher, _aliceId, 'm0');

      final result = await charlie.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _charlieId,
        envelope: env,
      );
      expect(result.dropped, isTrue);
      expect(result.plaintext, isNull);
    });

    test('wrong sender id → dropped (no record under that key)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final env = await _send(alice.cipher, _aliceId, 'm0');

      // The chat layer passes the message row's sender_id; a forged/relayed
      // row claiming bob sent alice's message finds no record.
      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _bobId,
        envelope: env,
      );
      expect(result.dropped, isTrue);
    });

    test('envelope senderIkDh differs from the stored bundle ik_dh → dropped', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final charlie = _Party(id: _charlieId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final env = await _send(alice.cipher, _aliceId, 'm0');
      final bytes = base64UrlNoPadDecode(env)!;
      final charlieIkDh = (await charlie.keyStore.loadOrCreateIdentity()).ikDhPublic;
      bytes.setRange(6, 38, charlieIkDh); // impersonate with a foreign ik_dh
      final forged = base64UrlNoPadEncode(bytes);

      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: forged,
      );
      expect(result.dropped, isTrue); // identity-change/session-reset drop
      expect(result.plaintext, isNull);
    });

    test('own message echo → dropped (sender cannot read own sender-key msgs)', () async {
      final alice = _Party(id: _aliceId);
      final env = await _send(alice.cipher, _aliceId, 'm0');
      final result = await alice.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: env,
      );
      expect(result.dropped, isTrue);
    });
  });

  group('distribution bundle', () {
    test('membersMissingSenderKey is PURE; markSenderKeyDistributed persists '
        'the per-sender distribution target set (members are not '
        're-distributed on every send)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);

      // Round 1: every active member except the sender is missing — the
      // computation alone persists NOTHING (2026-08-17 contract split).
      expect(
        await bob.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _bobId,
          activeMemberIds: const [_aliceId, _bobId],
        ),
        [_aliceId],
      );

      // The chat layer now distributes bob's bundle to the reported members
      // and marks them distributed ONLY after the row lands.
      await _distribute(bob.cipher, _bobId, [alice.cipher]);
      await bob.cipher.markSenderKeyDistributed(
        groupChatId: _groupChatId,
        senderUserId: _bobId,
        memberIds: const [_aliceId],
      );

      // Round 2 (same roster, no roster change / wipe): nobody is missing —
      // alice is not re-distributed on every send.
      expect(
        await bob.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _bobId,
          activeMemberIds: const [_aliceId, _bobId],
        ),
        isEmpty,
      );

      // A FRESH member appears → reported missing (and healed).
      expect(
        await bob.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _bobId,
          activeMemberIds: const [_aliceId, _bobId, _charlieId],
        ),
        [_charlieId],
      );
    });

    test('wrong group_id → ignored, no record persisted', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: '11111111-2222-3333-4444-555555555555',
        bundleJson: bundle,
      );
      expect(await _loadRecord(bob.sessionStore, _groupId, _aliceId), isNull);

      final env = await _send(alice.cipher, _aliceId, 'm0');
      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: env,
      );
      expect(result.dropped, isTrue);
    });

    test('wrong kind → ignored', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      final map = jsonDecode(bundle) as Map<String, dynamic>;
      map['kind'] = 'samay.something_else';
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: jsonEncode(map),
      );
      expect(await _loadRecord(bob.sessionStore, _groupId, _aliceId), isNull);
    });

    test('wrong version → ignored', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      final map = jsonDecode(bundle) as Map<String, dynamic>;
      map['v'] = 2;
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: jsonEncode(map),
      );
      expect(await _loadRecord(bob.sessionStore, _groupId, _aliceId), isNull);
    });

    test('sender_user_id mismatch → ignored', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _bobId, // row claims bob sent alice's bundle
        groupId: _groupId,
        bundleJson: bundle,
      );
      expect(await _loadRecord(bob.sessionStore, _groupId, _aliceId), isNull);
    });

    test('malformed JSON / missing fields → ignored (never throws)', () async {
      final bob = _Party(id: _bobId);

      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: 'not-json',
      );
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: '{"kind":"samay.group_sender_key"}',
      );
      expect(await _loadRecord(bob.sessionStore, _groupId, _aliceId), isNull);
    });

    test('own bundle echo → ignored, own chain keeps advancing', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final m0 = await _send(alice.cipher, _aliceId, 'm0');
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: m0,
        )).plaintext,
        'm0',
      );

      // Processing one's OWN bundle must be a no-op — otherwise the live
      // chain would reset to the distributed root and desync every member.
      await alice.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: bundle,
      );
      final record = await _loadRecord(alice.sessionStore, _groupId, _aliceId);
      expect(record!.lastSentN, 1, reason: 'chain must not reset');

      final m1 = await _send(alice.cipher, _aliceId, 'm1');
      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: m1,
      );
      expect(result.plaintext, 'm1'); // still index 1 — chain continuity
    });

    test('isSenderKeyBundle marker checks', () async {
      final alice = _Party(id: _aliceId);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      expect(await alice.cipher.isSenderKeyBundle(bundle), isTrue);
      expect(await alice.cipher.isSenderKeyBundle('hello world'), isFalse);
      expect(
        await alice.cipher.isSenderKeyBundle('{"kind":"samay.group_sender_key"}'),
        isTrue,
      );
      expect(await alice.cipher.isSenderKeyBundle('not-json'), isFalse);
    });
  });

  group('wipeGroupKeys (member removal → rekey)', () {
    test('deletes every record of the group; next send re-keys with a fresh root', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      await _distribute(bob.cipher, _bobId, [alice.cipher]);
      await _send(alice.cipher, _aliceId, 'm0');
      expect(await _loadRecord(alice.sessionStore, _groupId, _aliceId), isNotNull);
      expect(await _loadRecord(alice.sessionStore, _groupId, _bobId), isNotNull);
      expect(await _loadRecord(bob.sessionStore, _groupId, _aliceId), isNotNull);

      final rootBefore = (jsonDecode(
        await alice.cipher.senderKeyBundleJson(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          groupId: _groupId,
        ),
      ) as Map)['chain_root'] as String;

      // Round 1: bob is missing and becomes the (group, alice) target set —
      // the chat layer marks it distributed only AFTER the row lands.
      expect(
        await alice.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          activeMemberIds: const [_aliceId, _bobId],
        ),
        [_bobId],
      );
      await alice.cipher.markSenderKeyDistributed(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        memberIds: const [_bobId],
      );
      // After the mark: the persisted target set means nobody is
      // re-reported missing on the next round.
      expect(
        await alice.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          activeMemberIds: const [_aliceId, _bobId],
        ),
        isEmpty,
      );

      await alice.cipher.wipeGroupKeys(_groupChatId);

      expect(await _loadRecord(alice.sessionStore, _groupId, _aliceId), isNull);
      expect(await _loadRecord(alice.sessionStore, _groupId, _bobId), isNull);
      // The registry is NEVER deleted on wipe — it owns the group epoch. It
      // survives with senders + distribution sets cleared (epoch bumped 0→1).
      final registryJson = await alice.sessionStore.loadSession(
        '${GroupE2eeCipher.senderKeyRegistryKeyPrefix}$_groupChatId',
      );
      expect(registryJson, isNotNull);
      final registryMap = jsonDecode(registryJson!) as Map;
      expect(registryMap['epoch'], 1);
      expect(registryMap['senders'], isEmpty);
      expect(registryMap['distributed_to'], isEmpty);
      // Every record is gone → every active member is a distribution target
      // again (the sender itself is never listed).
      expect(
        await alice.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          activeMemberIds: const [_aliceId, _bobId],
        ),
        [_bobId],
      );
      // The next send mints a NEW chain root (rekey, not resumption) — in
      // the new group epoch (the fresh bundle must carry it).
      final freshBundle = jsonDecode(
        await alice.cipher.senderKeyBundleJson(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          groupId: _groupId,
        ),
      ) as Map;
      expect(freshBundle['chain_root'], isNot(rootBefore));
      expect(freshBundle['epoch'], 1);

      // Bob's device still holds the OLD-epoch record — the fresh-epoch
      // bundle must be ACCEPTED (epoch-based rekey; pre-fix the F2c
      // no-regress guard swallowed it as stale, so the rekeyed chain was
      // never readable on his device).
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      // The rekeyed message (chain index 0 of the fresh chain) decrypts.
      final env = await _send(alice.cipher, _aliceId, 'fresh');
      final rekeyed = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: env,
      );
      expect(rekeyed.plaintext, 'fresh',
          reason: 'the rekeyed chain must be readable once the fresh-epoch '
              'bundle is processed');
    });
  });

  group('rekey epochs (2026-08-17 live finding: message #2 undeliverable)', () {
    test('after wipeGroupKeys the fresh-epoch bundle is ACCEPTED by a '
        'receiver holding the old epoch, and the rekeyed message decrypts '
        '(the no-regress guard must not swallow legitimate rekeys)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      // Epoch 0: distribute + one message, decrypted by bob.
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final m0 = await _send(alice.cipher, _aliceId, 'm0');
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: m0,
        )).plaintext,
        'm0',
      );

      // Roster change → hard rekey (fresh epoch).
      await alice.cipher.wipeGroupKeys(_groupChatId);
      final bundle = jsonDecode(
        await alice.cipher.senderKeyBundleJson(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          groupId: _groupId,
        ),
      ) as Map;
      final epoch = bundle['epoch'] as int;
      expect(epoch, greaterThan(0),
          reason: 'the rekey bundle must carry a FRESH epoch (the wipe '
              'incremented the group epoch)');

      // The receiver must accept the fresh-epoch bundle even though its
      // chain_index (0) is <= the receiver's OLD-epoch lastSeenN — the live
      // bug: the F2c no-regress guard treated legitimate rekeys as stale, the
      // receiver never learned the new key, and every rekeyed message was
      // dropped (the sender saw blue "read" ticks anyway).
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: jsonEncode(bundle),
      );
      final bobRecord = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(bobRecord, isNotNull);
      expect(bobRecord!.epoch, epoch);

      // The rekeyed message (chain index 0 of the NEW epoch) decrypts on bob.
      final m1 = await _send(alice.cipher, _aliceId, 'fresh');
      final res = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: m1,
      );
      expect(res.plaintext, 'fresh',
          reason: 'the rekeyed chain must be readable once the fresh-epoch '
              'bundle is processed');
    });

    test('a stale bundle from the OLD epoch is still ignored after the rekey',
        () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      await _send(alice.cipher, _aliceId, 'm0');
      // Snapshot the epoch-0 bundle before the rekey.
      final oldBundle = jsonDecode(
        await alice.cipher.senderKeyBundleJson(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          groupId: _groupId,
        ),
      ) as Map;

      await alice.cipher.wipeGroupKeys(_groupChatId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]); // epoch 1
      expect((await _loadRecord(bob.sessionStore, _groupId, _aliceId))!.epoch, 1);

      // Replay the epoch-0 bundle → ignored, the epoch-1 record survives.
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: jsonEncode(oldBundle),
      );
      expect((await _loadRecord(bob.sessionStore, _groupId, _aliceId))!.epoch, 1);
    });

    test('same-epoch stale bundle (chain_index <= lastSeenN) is still ignored '
        '(F2c no-regress preserved)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final m0 = await _send(alice.cipher, _aliceId, 'm0');
      final m1 = await _send(alice.cipher, _aliceId, 'm1');
      // Bob consumes the epoch-0 chain: lastSeenN becomes 1.
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: m0,
        )).plaintext,
        'm0',
      );
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: m1,
        )).plaintext,
        'm1',
      );
      final rootAfter = (jsonDecode(
        await alice.cipher.senderKeyBundleJson(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          groupId: _groupId,
        ),
      ) as Map)['chain_root'] as String;

      // Re-distribute the same-epoch bundle (epoch 0, chain_index 1 ==
      // bob's lastSeenN) — the stale duplicate must be IGNORED.
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: jsonEncode({
          'v': e2eeSenderKeyBundleVersion,
          'kind': e2eeSenderKeyBundleKind,
          'group_id': _groupId,
          'chat_id': _groupChatId,
          'sender_user_id': _aliceId,
          'sender_ik_dh': (jsonDecode(
            await alice.cipher.senderKeyBundleJson(
              groupChatId: _groupChatId,
              senderUserId: _aliceId,
              groupId: _groupId,
            ),
          ) as Map)['sender_ik_dh'],
          'chain_root': rootAfter,
          'chain_index': 1,
          'epoch': 0,
          'created_at': DateTime.now().toIso8601String(),
        }),
      );
      // The record still points at the live chain: m2 decrypts.
      final m2 = await _send(alice.cipher, _aliceId, 'm2');
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: m2,
        )).plaintext,
        'm2',
      );
    });
  });

  group('reinstall heal (identity change supersedes the epoch guard)', () {
    test('(a) a reinstall mints a fresh identity + epoch-0 bundle; the '
        'receiver ACCEPTS it over the pre-reinstall epoch-2 record '
        '(identity change supersedes the epoch guard) and the reinstall-era '
        'message decrypts', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      // Two roster changes → the group epoch is 2: bob's device holds
      // alice's epoch-2 record with the OLD ik_dh.
      await alice.cipher.wipeGroupKeys(_groupChatId);
      await alice.cipher.wipeGroupKeys(_groupChatId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final preRecord = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(preRecord!.epoch, 2);

      // Alice reinstalls: a brand-new _Party = fresh identity + fresh
      // stores, no registry → the fresh chain is minted at epoch 0.
      final alice2 = _Party(id: _aliceId);
      final bundle = jsonDecode(await alice2.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      )) as Map;
      expect(bundle['epoch'], 0);
      expect(bundle['sender_ik_dh'], isNot(preRecord.senderIkDh),
          reason: 'the reinstall must produce a NEW identity ik_dh');

      // Pre-fix this is ignored (bundle epoch 0 < record epoch 2), the
      // receiver never learns the fresh chain, and every reinstall-era
      // message is dropped by the identity binding.
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: jsonEncode(bundle),
      );
      final healed = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(healed!.epoch, 0,
          reason: 'the identity-changed bundle must supersede the epoch '
              'guard (epoch 0 < record epoch 2)');
      expect(healed.senderIkDh, bundle['sender_ik_dh'],
          reason: 'the record must carry the NEW identity');
      expect(healed.lastSeenN, -1,
          reason: 'fresh chain at chain_index 0 → lastSeenN = -1');

      // The reinstall-era message (index 0 of the fresh chain) decrypts.
      final env = await _send(alice2.cipher, _aliceId, 'post-reinstall');
      final res = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: env,
      );
      expect(res.plaintext, 'post-reinstall');
      expect(res.dropped, isFalse);
    });

    test('(b) same-identity stale bundle still ignored after the reinstall '
        'heal (no-regress intact)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await alice.cipher.wipeGroupKeys(_groupChatId);
      await alice.cipher.wipeGroupKeys(_groupChatId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      // Reinstall → the healed record on bob is the fresh epoch-0 chain.
      final alice2 = _Party(id: _aliceId);
      final bundleJson = await alice2.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: bundleJson,
      );

      // Bob consumes two reinstall-era messages: lastSeenN = 1.
      final e0 = await _send(alice2.cipher, _aliceId, 'r0');
      final e1 = await _send(alice2.cipher, _aliceId, 'r1');
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: e0,
        )).plaintext,
        'r0',
      );
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: e1,
        )).plaintext,
        'r1',
      );
      final before = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(before!.lastSeenN, 1);
      expect(before.epoch, 0);

      // Replaying the SAME-identity epoch-0 bundle (chain_index 0 <=
      // lastSeenN 1) must still be IGNORED — the no-regress guard is
      // intact for unchanged identities.
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: bundleJson,
      );
      final after = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(after!.chainRoot, before.chainRoot,
          reason: 'stale same-identity bundle must not replace the live root');
      expect(after.lastSeenN, before.lastSeenN,
          reason: 'stale same-identity bundle must not reset lastSeenN');
      expect(after.epoch, before.epoch);
      expect(after.senderIkDh, before.senderIkDh);

      // Chain continuity: the next message still decrypts.
      final e2 = await _send(alice2.cipher, _aliceId, 'r2');
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: e2,
        )).plaintext,
        'r2',
      );
    });
  });

  group('K1 expectedSenderIkDh — identity bound to the delivering pairwise '
      'session (2026-08-16 re-audit)', () {
    test('(a) bundle ik_dh MISMATCHES the expected key → IGNORED, no record '
        'saved (a malicious member mints a bundle with a LEARNED foreign '
        'ik_dh)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      final map = jsonDecode(bundle) as Map;
      // The expected key is the delivering pairwise session's BOUND peer
      // key — a DIFFERENT 32-byte key than the bundle's self-attested
      // sender_ik_dh (the K1 attack shape: sender_user_id is RLS-bound but
      // the ik_dh was learned from another member's published bundle).
      final foreign =
          base64UrlNoPadEncode(Uint8List.fromList(List.filled(32, 0x41)));
      expect(foreign, isNot(map['sender_ik_dh']));
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: bundle,
        expectedSenderIkDh: foreign,
      );
      expect(await _loadRecord(bob.sessionStore, _groupId, _aliceId), isNull,
          reason: 'a bundle whose ik_dh is not bound to the delivering '
              'pairwise session must never be accepted');
    });

    test('(b) bundle ik_dh MATCHES the expected key → ACCEPTED (the '
        'reinstall-heal path still works when the pairwise session bound '
        'the NEW identity)', () async {
      final alice2 = _Party(id: _aliceId); // reinstall: fresh identity
      final bob = _Party(id: _bobId);
      final bundle = await alice2.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      final map = jsonDecode(bundle) as Map;
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: bundle,
        expectedSenderIkDh: map['sender_ik_dh'] as String,
      );
      final record = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(record, isNotNull);
      expect(record!.senderIkDh, map['sender_ik_dh'],
          reason: 'the expected key is the pairwise-bound NEW identity — '
              'the heal must accept it');
    });

    test('(c) a spoofed ik_dh is ignored even against an EXISTING record — '
        'the identity-change heal never accepts a bundle whose ik_dh the '
        'delivering session did not bind', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      // Two roster changes → epoch 2; bob holds alice's epoch-2 record.
      await alice.cipher.wipeGroupKeys(_groupChatId);
      await alice.cipher.wipeGroupKeys(_groupChatId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final pre = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(pre!.epoch, 2);

      // Hand-crafted spoof: SAME sender_user_id (alice, RLS-bound) but a
      // FOREIGN ik_dh (a learned key) at a HIGHER epoch — pre-fix the
      // identity-change branch would accept it regardless of epoch.
      final aliceIdentity = await alice.keyStore.loadOrCreateIdentity();
      final spoofed = {
        'v': e2eeSenderKeyBundleVersion,
        'kind': e2eeSenderKeyBundleKind,
        'group_id': _groupId,
        'chat_id': _groupChatId,
        'sender_user_id': _aliceId,
        'sender_ik_dh':
            base64UrlNoPadEncode(Uint8List.fromList(List.filled(32, 0x42))),
        'chain_root':
            base64UrlNoPadEncode(Uint8List.fromList(List.filled(32, 0x43))),
        'chain_index': 0,
        'epoch': 5,
        'created_at': '2026-08-16T00:00:00Z',
      };
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: jsonEncode(spoofed),
        expectedSenderIkDh: base64UrlNoPadEncode(aliceIdentity.ikDhPublic),
      );
      final post = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(post!.epoch, 2, reason: 'the pre-reinstall record is kept');
      expect(post.senderIkDh, pre.senderIkDh,
          reason: 'the spoofed ik_dh must never replace the bound record');
    });

    test('(d) malformed expectedSenderIkDh → IGNORED (never a throw)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: bundle,
        expectedSenderIkDh: 'not-base64url',
      );
      expect(await _loadRecord(bob.sessionStore, _groupId, _aliceId), isNull);
    });
  });

  group('envelope type routing', () {
    test('isSenderKeyEnvelope distinguishes 0x03 from 0x01/0x02', () async {
      final alice = _Party(id: _aliceId);

      final groupEnv = SamayEnvelope.senderKey(
        senderIkDh: Uint8List(32),
        groupId: groupIdToBytes(_groupId),
        chainIndex: 0,
        ciphertext: Uint8List(16),
      );
      expect(
        await alice.cipher.isSenderKeyEnvelope(
          base64UrlNoPadEncode(groupEnv.encode()),
        ),
        isTrue,
      );

      final ratchet = SamayEnvelope(
        type: e2eeEnvelopeTypeRatchet,
        senderIkDh: Uint8List(32),
        senderIkSig: Uint8List(32),
        dhPub: Uint8List(32),
        pn: 0,
        n: 0,
        ciphertext: Uint8List(16),
      );
      expect(
        await alice.cipher.isSenderKeyEnvelope(
          base64UrlNoPadEncode(ratchet.encode()),
        ),
        isFalse,
      );

      final init = SamayEnvelope(
        type: e2eeEnvelopeTypeInit,
        senderIkDh: Uint8List(32),
        senderIkSig: Uint8List(32),
        recipientIkDh: Uint8List(32),
        ekA: Uint8List(32),
        spkId: 1,
        opkId: e2eeNoOpkId,
        dhPub: Uint8List(32),
        pn: 0,
        n: 0,
        ciphertext: Uint8List(16),
      );
      expect(
        await alice.cipher.isSenderKeyEnvelope(
          base64UrlNoPadEncode(init.encode()),
        ),
        isFalse,
      );
      expect(await alice.cipher.isSenderKeyEnvelope('garbage!!'), isFalse);
    });
  });

  group('audit fixes (F1 bounded gap / F2 re-distribution + no-regress / '
      'F4 cross-group chat binding)', () {
    test('F1: chainIndex = 0xFFFFFFFF → dropped, record untouched, and '
        'dropped again on a second call (no DoS walk)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      final rootAtDistribution =
          (jsonDecode(bundle) as Map)['chain_root'] as String;

      // The attacker posts a 0x03 row whose header chain_index is u32 max:
      // pre-fix the receiver walks ~4.29e9 HKDF steps before the AEAD check
      // (remote CPU DoS) — the timeout below makes the pre-fix suite fail
      // fast instead of hanging; post-fix the cap drops it in O(1).
      final identity = await alice.keyStore.loadOrCreateIdentity();
      final malicious = base64UrlNoPadEncode(
        SamayEnvelope.senderKey(
          senderIkDh: identity.ikDhPublic,
          groupId: groupIdToBytes(_groupId),
          chainIndex: 0xFFFFFFFF,
          ciphertext: Uint8List(16),
        ).encode(),
      );

      final first = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: malicious,
      );
      expect(first.dropped, isTrue);
      expect(first.failed, isFalse);
      expect(first.plaintext, isNull);
      // The record must NOT advance — pre-fix the AEAD failure still does
      // not advance it, but the unbounded walk is the bug.
      final after = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(after!.lastSeenN, -1, reason: 'record lastSeenN must not advance');
      expect(after.chainRoot, rootAtDistribution,
          reason: 'record chainRoot must not advance');

      final second = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: malicious,
      );
      expect(second.dropped, isTrue);
      expect(
        (await _loadRecord(bob.sessionStore, _groupId, _aliceId))!.lastSeenN,
        -1,
        reason: 'record must still not advance after the second call',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('F1: a chain gap just over the cap is dropped without derivation; '
        'a small gap with AEAD failure is failed', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final identity = await alice.keyStore.loadOrCreateIdentity();

      Future<String> crafted(int chainIndex) => Future.value(base64UrlNoPadEncode(
            SamayEnvelope.senderKey(
              senderIkDh: identity.ikDhPublic,
              groupId: groupIdToBytes(_groupId),
              chainIndex: chainIndex,
              ciphertext: Uint8List(16),
            ).encode(),
          ));

      // lastSeenN = -1 → gap = 2002 > e2eeSenderKeyMaxSkip (2000) → drop.
      final overCap = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: await crafted(e2eeSenderKeyMaxSkip + 2),
      );
      expect(overCap.dropped, isTrue);
      expect(overCap.failed, isFalse);

      // Small gap (6) — the walk runs, the AEAD check fails → genuine
      // undecryptable bubble, NOT a protocol drop.
      final smallGap = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: await crafted(5),
      );
      expect(smallGap.failed, isTrue);
      expect(smallGap.dropped, isFalse);
    });

    test('F2a: same-epoch re-distribution does NOT desync receivers (both '
        'messages decrypt)', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final m0 = await _send(alice.cipher, _aliceId, 'm0');
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: m0,
        )).plaintext,
        'm0',
      );

      // Re-distribution of the SAME epoch (lazy heal / group re-open). Pre-
      // fix the bundle hardcodes chain_index 0 while carrying the advanced
      // root → the record resets and every later message fails AEAD.
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final m1 = await _send(alice.cipher, _aliceId, 'm1');
      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: m1,
      );
      expect(result.plaintext, 'm1');
      expect(result.dropped, isFalse);
      expect(result.failed, isFalse);
    });

    test('F2c: a stale/duplicate bundle never overwrites a live record', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      final originalBundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      final m0 = await _send(alice.cipher, _aliceId, 'm0');
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: m0,
        )).plaintext,
        'm0',
      );
      final before = await _loadRecord(bob.sessionStore, _groupId, _aliceId);

      // The original bundle (chain_index 0) arrives late — pre-fix it
      // overwrites the live record and resets lastSeenN (desync).
      await bob.cipher.processSenderKeyBundle(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
        bundleJson: originalBundle,
      );

      final after = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(after!.chainRoot, before!.chainRoot,
          reason: 'stale bundle must not replace the live chain root');
      expect(after.lastSeenN, before.lastSeenN,
          reason: 'stale bundle must not reset lastSeenN');

      // Chain continuity: the next message still decrypts.
      final m1 = await _send(alice.cipher, _aliceId, 'm1');
      expect(
        (await bob.cipher.decrypt(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          envelope: m1,
        )).plaintext,
        'm1',
      );
    });

    test('F2b: markSenderKeyDistributed persists the target set — the '
        'recipient and the sender are excluded, a fresh member is missing',
        () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);

      // Round 1: every other member is a target (pure computation).
      expect(
        await bob.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _bobId,
          activeMemberIds: const [_aliceId, _bobId],
        ),
        [_aliceId],
      );
      await _distribute(bob.cipher, _bobId, [alice.cipher]);
      // The chat layer marks the member distributed after the row lands.
      await bob.cipher.markSenderKeyDistributed(
        groupChatId: _groupChatId,
        senderUserId: _bobId,
        memberIds: const [_aliceId],
      );

      // Round 2: alice (M) is excluded — the sender is never reported.
      expect(
        await bob.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _bobId,
          activeMemberIds: const [_aliceId, _bobId],
        ),
        isEmpty,
      );
      // A fresh member is reported missing.
      expect(
        await bob.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _bobId,
          activeMemberIds: const [_aliceId, _bobId, _charlieId],
        ),
        [_charlieId],
      );
    });

    test('F4: record bound to its chat — a G2-chain envelope posted into '
        'G1\'s thread is dropped, not shown', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      // Alice's G2 chain is distributed and used in chat-2 (the G2 group's
      // chat): the record on bob's device is bound to chat-2.
      await _distribute(
        alice.cipher,
        _aliceId,
        [bob.cipher],
        groupId: _otherGroupId,
        groupChatId: _otherChatId,
      );
      // The confusion vector: a message encrypted with the G2 CHAIN but
      // bound (AEAD aad) to chat-1 — a "G2-chain row posted into G1's
      // thread". Pre-fix the (G2, alice) record decrypts it and it SHOWS in
      // chat-1; post-fix the record's chatId binding drops it silently.
      final confused = await alice.cipher.encrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _otherGroupId,
        plaintext: 'confused',
      );
      final result = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: confused,
      );
      expect(result.dropped, isTrue);
      expect(result.failed, isFalse);
      expect(result.plaintext, isNull);
    });
  });

  group('on-device migration (records v1/v2 are treated as absent → '
      're-distribution heals to v3)', () {
    test('a persisted v1 record (version 1, no chat_id) is rejected by '
        'fromJson, decrypt drops (NoSession), and re-distribution heals to '
        'a v3 record', () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      await _send(alice.cipher, _aliceId, 'm0');

      // Simulate the pre-fix on-device state: overwrite the live v3 record
      // with the v1 shape (version 1, no chat_id).
      await bob.sessionStore.saveSession(
        _recordKey(_groupId, _aliceId),
        jsonEncode({
          'version': 1,
          'sender_user_id': _aliceId,
          'sender_ik_dh': base64UrlNoPadEncode(Uint8List.fromList(
            List<int>.filled(32, 7),
          )),
          'chain_root': base64UrlNoPadEncode(Uint8List.fromList(
            List<int>.filled(32, 9),
          )),
          'last_sent_n': 0,
          'last_seen_n': -1,
          'created_at': DateTime.now().toIso8601String(),
        }),
      );

      final raw =
          await bob.sessionStore.loadSession(_recordKey(_groupId, _aliceId));
      expect(raw, isNotNull);
      expect(GroupSenderKeyRecord.fromJson(raw!), isNull,
          reason: 'a v1 record fails the version guard → treated as absent');

      // The next message is a NoSession-style protocol drop — never an AEAD
      // bubble (for the cipher the record simply does not exist).
      final m1 = await _send(alice.cipher, _aliceId, 'm1');
      final dropped = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: m1,
      );
      expect(dropped.dropped, isTrue);
      expect(dropped.failed, isFalse);
      expect(dropped.plaintext, isNull);

      // Re-distribution heals the device: a fresh v3 bundle replaces the
      // stale v1 state (one round, then stable) and the chain resumes.
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final healed = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(healed, isNotNull);
      expect(healed!.chatId, _groupChatId);
      expect(healed.lastSeenN, 1,
          reason: 'bundle chain_index (=2 after m0/m1) minus 1');

      final m2 = await _send(alice.cipher, _aliceId, 'm2');
      final resumed = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: m2,
      );
      expect(resumed.plaintext, 'm2');
    });

    test('a persisted v2 record (version 2, no epoch) is rejected by '
        'fromJson — treated as absent, re-distribution heals to a v3 record',
        () async {
      final alice = _Party(id: _aliceId);
      final bob = _Party(id: _bobId);
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);

      // The 2026-08-16 audit shape: v2 carries chat_id but NO epoch (the
      // v3 field that distinguishes a genuine rekey from a stale duplicate).
      await bob.sessionStore.saveSession(
        _recordKey(_groupId, _aliceId),
        jsonEncode({
          'version': 2,
          'chat_id': _groupChatId,
          'sender_user_id': _aliceId,
          'sender_ik_dh': base64UrlNoPadEncode(Uint8List.fromList(
            List<int>.filled(32, 7),
          )),
          'chain_root': base64UrlNoPadEncode(Uint8List.fromList(
            List<int>.filled(32, 9),
          )),
          'last_sent_n': 0,
          'last_seen_n': -1,
          'created_at': DateTime.now().toIso8601String(),
        }),
      );

      final raw =
          await bob.sessionStore.loadSession(_recordKey(_groupId, _aliceId));
      expect(raw, isNotNull);
      expect(GroupSenderKeyRecord.fromJson(raw!), isNull,
          reason: 'a v2 record fails the epoch guard → treated as absent');

      // Re-distribution heals the device: a v3 record replaces the stale
      // v2 state (one round, then stable).
      await _distribute(alice.cipher, _aliceId, [bob.cipher]);
      final healed = await _loadRecord(bob.sessionStore, _groupId, _aliceId);
      expect(healed, isNotNull);
      expect(healed!.epoch, 0);
      expect(healed.chatId, _groupChatId);

      final m1 = await _send(alice.cipher, _aliceId, 'm1');
      final resumed = await bob.cipher.decrypt(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        envelope: m1,
      );
      expect(resumed.plaintext, 'm1');
    });
  });

  group('key-request retry protocol (2026-08-17 missing-chain deadlock heal)',
      () {
    test('isSenderKeyRequest: true for a well-formed request, false for a '
        'bundle or any non-request plaintext', () async {
      final alice = _Party(id: _aliceId);
      final request = await alice.cipher.senderKeyRequestJson(
        groupChatId: _groupChatId,
        groupId: _groupId,
        missingSenderUserId: _aliceId,
      );
      expect(await alice.cipher.isSenderKeyRequest(request), isTrue);
      expect(await alice.cipher.isSenderKeyRequest('hola'), isFalse);
      expect(await alice.cipher.isSenderKeyRequest('{not json'), isFalse);
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      expect(await alice.cipher.isSenderKeyRequest(bundle), isFalse);
    });

    test('senderKeyRequestTarget round-trips the missing-sender id and '
        'rejects foreign group/chat/kind/version', () async {
      final alice = _Party(id: _aliceId);
      final request = await alice.cipher.senderKeyRequestJson(
        groupChatId: _groupChatId,
        groupId: _groupId,
        missingSenderUserId: _aliceId,
      );
      expect(
        await alice.cipher.senderKeyRequestTarget(
          json: request,
          groupChatId: _groupChatId,
          groupId: _groupId,
        ),
        _aliceId,
      );

      // A request for a DIFFERENT group/chat is not actionable on this chat
      // (cross-group confusion, the F4 analogue for requests).
      final foreign = await alice.cipher.senderKeyRequestJson(
        groupChatId: _otherChatId,
        groupId: _otherGroupId,
        missingSenderUserId: _aliceId,
      );
      expect(
        await alice.cipher.senderKeyRequestTarget(
          json: foreign,
          groupChatId: _groupChatId,
          groupId: _groupId,
        ),
        isNull,
      );

      // A bundle (wrong kind) and junk are not requests.
      final bundle = await alice.cipher.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        groupId: _groupId,
      );
      expect(
        await alice.cipher.senderKeyRequestTarget(
          json: bundle,
          groupChatId: _groupChatId,
          groupId: _groupId,
        ),
        isNull,
      );
      expect(
        await alice.cipher.senderKeyRequestTarget(
          json: 'nonsense',
          groupChatId: _groupChatId,
          groupId: _groupId,
        ),
        isNull,
      );
    });

    test('unmarkSenderKeyDistributed: a member un-marked is reported missing '
        'again; unrelated senders/members are untouched; absent registry '
        'no-ops', () async {
      final alice = _Party(id: _aliceId);
      await alice.cipher.markSenderKeyDistributed(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        memberIds: [_bobId, _charlieId],
      );
      expect(
        await alice.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          activeMemberIds: [_aliceId, _bobId, _charlieId],
        ),
        isEmpty,
      );

      // Bob un-marked → missing again; charlie stays marked.
      await alice.cipher.unmarkSenderKeyDistributed(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        memberIds: [_bobId],
      );
      expect(
        await alice.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          activeMemberIds: [_aliceId, _bobId, _charlieId],
        ),
        [_bobId],
      );

      // Un-marking members who were never marked is a no-op.
      await alice.cipher.unmarkSenderKeyDistributed(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        memberIds: [_bobId, 'dave'],
      );
      expect(
        await alice.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _aliceId,
          activeMemberIds: [_aliceId, _bobId, _charlieId, 'dave'],
        ),
        [_bobId, 'dave'],
      );

      // Another sender's marks are untouched by alice's unmark.
      await alice.cipher.markSenderKeyDistributed(
        groupChatId: _groupChatId,
        senderUserId: _charlieId,
        memberIds: [_bobId],
      );
      await alice.cipher.unmarkSenderKeyDistributed(
        groupChatId: _groupChatId,
        senderUserId: _aliceId,
        memberIds: [_bobId],
      );
      expect(
        await alice.cipher.membersMissingSenderKey(
          groupChatId: _groupChatId,
          senderUserId: _charlieId,
          activeMemberIds: [_aliceId, _bobId, _charlieId],
        ),
        [_aliceId],
      );
    });
  });
}
