import GRDB

/// Numbered migrations. Never edit a migration after it has shipped; add a new one.
enum Schema {
    // swiftlint:disable:next function_body_length
    static func v1(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE accounts (
          id TEXT PRIMARY KEY,
          email TEXT NOT NULL UNIQUE,
          display_name TEXT, avatar_url TEXT,
          history_id TEXT,
          backfill_cursor TEXT,
          backfill_done INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'ok',
          categories_enabled INTEGER NOT NULL DEFAULT 1,
          sort_order INTEGER NOT NULL DEFAULT 0,
          added_at INTEGER NOT NULL
        );

        CREATE TABLE labels (
          account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
          id TEXT NOT NULL,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          color_bg TEXT, color_text TEXT,
          visible_in_list INTEGER NOT NULL DEFAULT 1,
          threads_unread INTEGER NOT NULL DEFAULT 0,
          threads_total INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (account_id, id)
        );

        CREATE TABLE threads (
          account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
          id TEXT NOT NULL,
          subject TEXT, snippet TEXT,
          last_date INTEGER NOT NULL,
          participants TEXT NOT NULL,
          message_count INTEGER NOT NULL,
          has_attachments INTEGER NOT NULL DEFAULT 0,
          is_unread INTEGER NOT NULL DEFAULT 0,
          is_starred INTEGER NOT NULL DEFAULT 0,
          is_important INTEGER NOT NULL DEFAULT 0,
          history_id TEXT,
          PRIMARY KEY (account_id, id)
        );
        CREATE INDEX threads_by_date ON threads(account_id, last_date DESC);

        CREATE TABLE thread_labels (
          account_id TEXT NOT NULL, thread_id TEXT NOT NULL, label_id TEXT NOT NULL,
          last_date INTEGER NOT NULL,
          PRIMARY KEY (account_id, thread_id, label_id)
        );
        CREATE INDEX thread_labels_list ON thread_labels(account_id, label_id, last_date DESC);
        CREATE INDEX thread_labels_unified ON thread_labels(label_id, last_date DESC);

        CREATE TABLE messages (
          rowid INTEGER PRIMARY KEY,
          account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
          id TEXT NOT NULL, thread_id TEXT NOT NULL,
          history_id TEXT, internal_date INTEGER NOT NULL,
          from_name TEXT, from_email TEXT,
          to_json TEXT, cc_json TEXT, bcc_json TEXT, reply_to TEXT,
          subject TEXT, snippet TEXT,
          rfc_message_id TEXT, in_reply_to TEXT, references_hdr TEXT,
          list_unsubscribe TEXT, list_unsubscribe_post TEXT,
          size_estimate INTEGER,
          has_attachments INTEGER NOT NULL DEFAULT 0,
          is_unread INTEGER NOT NULL DEFAULT 0,
          is_draft INTEGER NOT NULL DEFAULT 0,
          body_state TEXT NOT NULL DEFAULT 'none',
          UNIQUE (account_id, id)
        );
        CREATE INDEX messages_thread ON messages(account_id, thread_id, internal_date);

        CREATE TABLE message_labels (
          account_id TEXT NOT NULL, message_id TEXT NOT NULL, label_id TEXT NOT NULL,
          PRIMARY KEY (account_id, message_id, label_id)
        );

        CREATE TABLE message_bodies (
          account_id TEXT NOT NULL, message_id TEXT NOT NULL,
          html TEXT, plain TEXT,
          display_html TEXT,
          body_text TEXT,
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY (account_id, message_id)
        );

        CREATE TABLE attachments (
          account_id TEXT NOT NULL, message_id TEXT NOT NULL, part_id TEXT NOT NULL,
          attachment_id TEXT, filename TEXT, mime_type TEXT, size INTEGER,
          content_id TEXT, is_inline INTEGER NOT NULL DEFAULT 0,
          local_path TEXT,
          PRIMARY KEY (account_id, message_id, part_id)
        );

        CREATE TABLE contacts (
          account_id TEXT NOT NULL, email TEXT NOT NULL COLLATE NOCASE,
          name TEXT, source TEXT NOT NULL,
          last_seen INTEGER, times_sent_to INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (account_id, email)
        );

        CREATE TABLE send_as (
          account_id TEXT NOT NULL, email TEXT NOT NULL,
          display_name TEXT, signature_html TEXT,
          is_default INTEGER NOT NULL DEFAULT 0, is_primary INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (account_id, email)
        );

        CREATE TABLE pending_actions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          account_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          payload TEXT NOT NULL,
          undo_payload TEXT,
          state TEXT NOT NULL DEFAULT 'queued',
          not_before INTEGER,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          created_at INTEGER NOT NULL
        );
        CREATE INDEX pending_actions_queue ON pending_actions(account_id, state, not_before);

        CREATE TABLE remote_content_allow (
          account_id TEXT NOT NULL, sender TEXT NOT NULL COLLATE NOCASE,
          PRIMARY KEY (account_id, sender)
        );

        CREATE VIRTUAL TABLE messages_fts USING fts5(
          subject, from_text, to_text, body_text,
          content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2'
        );
        """)
    }
}
