PRAGMA user_version = 1;

CREATE TABLE snapshot_roots (
    root_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    virtual_path TEXT NOT NULL CHECK (virtual_path = '/'),
    current_generation INTEGER NOT NULL CHECK (current_generation > 0),
    logical_bytes INTEGER NOT NULL CHECK (logical_bytes >= 0),
    file_count INTEGER NOT NULL CHECK (file_count >= 0),
    dir_count INTEGER NOT NULL CHECK (dir_count >= 1),
    collected_at TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('ready', 'stale', 'failed')),
    error TEXT NOT NULL DEFAULT ''
);

CREATE TABLE namespace_entries (
    root_id TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation > 0),
    relative_path TEXT NOT NULL CHECK (substr(relative_path, 1, 1) = '/'),
    parent_path TEXT NOT NULL,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('directory', 'file', 'aggregate')),
    depth INTEGER NOT NULL CHECK (depth >= 0 AND depth <= 3),
    logical_bytes INTEGER NOT NULL CHECK (logical_bytes >= 0),
    recursive_bytes INTEGER NOT NULL CHECK (recursive_bytes >= 0),
    file_count INTEGER NOT NULL CHECK (file_count >= 0),
    dir_count INTEGER NOT NULL CHECK (dir_count >= 0),
    modified_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (root_id, generation, relative_path),
    FOREIGN KEY (root_id) REFERENCES snapshot_roots(root_id)
);

CREATE INDEX idx_namespace_entries_tree
ON namespace_entries(root_id, generation, relative_path);

PRAGMA optimize;
