-- =============================================================================
-- 20260817000003 — Group chat sender-key DISTRIBUTION addressing (ISSUE 4 / D3)
-- -----------------------------------------------------------------------------
-- Group chat E2EE (Signal sender keys, ISSUE 4) delivers a member's sender-key
-- chain to every other member as an ordinary `messages` row whose PLAINTEXT is
-- the bundle JSON (lib/crypto/group_cipher.dart `senderKeyBundleJson`),
-- encrypted under a PER-PAIRWISE `E2eeSession` (X3DH — the distributor is the
-- initiator, the target is the responder). These distribution rows must be
-- addressable to exactly ONE target so non-target members can skip them
-- without even attempting decryption:
--
--   recipient_id uuid NULL   — the target member of a distribution row
--
--   * recipient_id = <me>        → the pairwise envelope decrypts to the
--     bundle JSON; the client processes it and hides the row (never a bubble).
--   * recipient_id = <other>     → NOT the target: the client skips the row
--     silently (no bubble, no decrypt attempt).
--   * recipient_id IS NULL       → an ordinary message row (type-0x03 sender-
--     key envelope in group chats; plaintext/1:1 envelopes in direct/event
--     chats — unchanged).
--
-- NO RLS change is made here: group chat rows stay readable by every active
-- member (migration 20260817000002 `messages_read_participant`). The envelope
-- (ciphertext — the peer without the pairwise session cannot read the bundle)
-- and the client-side recipient_id skip provide the privacy; RLS keeps
-- non-members out entirely. A second recipient_id row is fully transparent to
-- the message-cap trigger, realtime publication and the inbox RPC.
-- =============================================================================

ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS recipient_id uuid NULL;

COMMENT ON COLUMN public.messages.recipient_id IS
  'Sender-key distribution targeting (ISSUE 4): the target member of a '
  'sender-key bundle row (per-pairwise E2EE envelope of the bundle JSON). '
  'Non-target members skip rows where recipient_id <> me silently — the '
  'envelope + client-side skip, not RLS, provide the distribution privacy. '
  'NULL on ordinary message rows.';
