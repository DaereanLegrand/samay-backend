-- Performance indexes for read-heavy queries (audit finding L10)

-- Index for "all messages I've read" queries on message_reads
CREATE INDEX IF NOT EXISTS idx_message_reads_user ON public.message_reads(user_id);

-- Partial index for "unread messages" queries (most messages are unread)
CREATE INDEX IF NOT EXISTS idx_messages_read_at ON public.messages(read_at) WHERE read_at IS NULL;
