PRAGMA foreign_keys = ON;

CREATE TABLE notebooks (
  id TEXT PRIMARY KEY NOT NULL,
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  read_only INTEGER NOT NULL DEFAULT 0 CHECK (read_only IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE notes (
  id TEXT PRIMARY KEY NOT NULL,
  notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  body_markdown TEXT NOT NULL CHECK (length(trim(body_markdown)) > 0),
  read_only INTEGER NOT NULL DEFAULT 0 CHECK (read_only IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;

CREATE INDEX notes_notebook_updated_idx
  ON notes(notebook_id, updated_at DESC, id);

CREATE TABLE tags (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL UNIQUE CHECK (name = lower(trim(name)) AND length(name) > 0),
  class_name TEXT,
  created_at TEXT NOT NULL
) STRICT;

CREATE TABLE note_tags (
  note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  provenance TEXT NOT NULL CHECK (provenance IN ('human', 'ai', 'system')),
  PRIMARY KEY (note_id, tag_id)
) WITHOUT ROWID, STRICT;

CREATE INDEX note_tags_tag_idx ON note_tags(tag_id, note_id);

CREATE TABLE note_links (
  source_note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  target_note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  PRIMARY KEY (source_note_id, target_note_id),
  CHECK (source_note_id <> target_note_id)
) WITHOUT ROWID, STRICT;

CREATE INDEX note_links_target_idx ON note_links(target_note_id, source_note_id);

CREATE VIRTUAL TABLE notes_fts USING fts5(
  title,
  body_markdown,
  content='notes',
  content_rowid='rowid',
  tokenize='unicode61'
);

CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN
  INSERT INTO notes_fts(rowid, title, body_markdown)
  VALUES (new.rowid, new.title, new.body_markdown);
END;

CREATE TRIGGER notes_fts_delete AFTER DELETE ON notes BEGIN
  INSERT INTO notes_fts(notes_fts, rowid, title, body_markdown)
  VALUES ('delete', old.rowid, old.title, old.body_markdown);
END;

CREATE TRIGGER notes_fts_update AFTER UPDATE OF title, body_markdown ON notes BEGIN
  INSERT INTO notes_fts(notes_fts, rowid, title, body_markdown)
  VALUES ('delete', old.rowid, old.title, old.body_markdown);
  INSERT INTO notes_fts(rowid, title, body_markdown)
  VALUES (new.rowid, new.title, new.body_markdown);
END;

INSERT INTO notebooks (id, title, read_only, created_at, updated_at)
VALUES ('default', 'Default', 0, datetime('now'), datetime('now'));
