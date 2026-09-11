package portal

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"time"

	_ "modernc.org/sqlite"
)

const (
	namespaceSchemaVersion = 1
	namespaceMaxTreeRows   = 10000
	namespaceFreshFor      = 3 * time.Minute
)

var (
	namespaceRootIDPattern  = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	errNamespaceRootMissing = errors.New("namespace root not found")
)

type namespaceRoot struct {
	ID           string `json:"id"`
	DisplayName  string `json:"displayName"`
	VirtualPath  string `json:"path"`
	LogicalBytes int64  `json:"logicalBytes"`
	FileCount    int64  `json:"fileCount"`
	DirCount     int64  `json:"dirCount"`
	CollectedAt  string `json:"collectedAt"`
	Status       string `json:"status"`
	Error        string `json:"error,omitempty"`
	generation   int64
}

type namespaceEntry struct {
	Path           string `json:"path"`
	ParentPath     string `json:"parentPath"`
	Name           string `json:"name"`
	Kind           string `json:"kind"`
	Depth          int    `json:"depth"`
	LogicalBytes   int64  `json:"logicalBytes"`
	RecursiveBytes int64  `json:"recursiveBytes"`
	FileCount      int64  `json:"fileCount"`
	DirCount       int64  `json:"dirCount"`
	ModifiedAt     string `json:"modifiedAt,omitempty"`
}

type namespaceSource interface {
	roots(context.Context) ([]namespaceRoot, error)
	tree(context.Context, string, int) (namespaceRoot, []namespaceEntry, error)
}

type fixtureNamespaceDocument struct {
	Roots   []namespaceRoot  `json:"roots"`
	Entries []fixtureEntries `json:"entries"`
}

type fixtureEntries struct {
	RootID  string           `json:"rootId"`
	Entries []namespaceEntry `json:"items"`
}

type fixtureNamespaceSource struct {
	document fixtureNamespaceDocument
}

func newFixtureNamespaceSource(path string) (*fixtureNamespaceSource, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read namespace fixture: %w", err)
	}
	var document fixtureNamespaceDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("decode namespace fixture: %w", err)
	}
	if len(document.Roots) == 0 {
		return nil, errors.New("namespace fixture has no roots")
	}
	return &fixtureNamespaceSource{document: document}, nil
}

func (s *fixtureNamespaceSource) roots(context.Context) ([]namespaceRoot, error) {
	return append([]namespaceRoot(nil), s.document.Roots...), nil
}

func (s *fixtureNamespaceSource) tree(_ context.Context, rootID string, maxDepth int) (namespaceRoot, []namespaceEntry, error) {
	var root namespaceRoot
	found := false
	for _, candidate := range s.document.Roots {
		if candidate.ID == rootID {
			root = candidate
			found = true
			break
		}
	}
	if !found {
		return namespaceRoot{}, nil, errNamespaceRootMissing
	}
	var result []namespaceEntry
	for _, group := range s.document.Entries {
		if group.RootID != rootID {
			continue
		}
		for _, entry := range group.Entries {
			if entry.Depth <= maxDepth {
				result = append(result, entry)
			}
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Path < result[j].Path })
	return root, result, nil
}

type sqliteNamespaceSource struct {
	db *sql.DB
}

func newSQLiteNamespaceSource(path string) (*sqliteNamespaceSource, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("namespace database path must be absolute")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("stat namespace database: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("namespace database must be a regular non-symlink file")
	}
	dsn := (&url.URL{Scheme: "file", Path: path}).String() + "?mode=ro&_pragma=query_only(1)&_pragma=busy_timeout(1000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open namespace database: %w", err)
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var version int
	if err := db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		db.Close()
		return nil, fmt.Errorf("read namespace schema: %w", err)
	}
	if version != namespaceSchemaVersion {
		db.Close()
		return nil, fmt.Errorf("namespace schema version %d, expected %d", version, namespaceSchemaVersion)
	}
	return &sqliteNamespaceSource{db: db}, nil
}

func (s *sqliteNamespaceSource) roots(ctx context.Context) ([]namespaceRoot, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT root_id, display_name, virtual_path, logical_bytes, file_count,
		       dir_count, collected_at, status, error, current_generation
		FROM snapshot_roots ORDER BY display_name, root_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []namespaceRoot
	for rows.Next() {
		var root namespaceRoot
		if err := rows.Scan(&root.ID, &root.DisplayName, &root.VirtualPath, &root.LogicalBytes,
			&root.FileCount, &root.DirCount, &root.CollectedAt, &root.Status, &root.Error, &root.generation); err != nil {
			return nil, err
		}
		result = append(result, root)
	}
	return result, rows.Err()
}

func (s *sqliteNamespaceSource) tree(ctx context.Context, rootID string, maxDepth int) (namespaceRoot, []namespaceEntry, error) {
	var root namespaceRoot
	err := s.db.QueryRowContext(ctx, `
		SELECT root_id, display_name, virtual_path, logical_bytes, file_count,
		       dir_count, collected_at, status, error, current_generation
		FROM snapshot_roots WHERE root_id = ?`, rootID).Scan(
		&root.ID, &root.DisplayName, &root.VirtualPath, &root.LogicalBytes,
		&root.FileCount, &root.DirCount, &root.CollectedAt, &root.Status, &root.Error, &root.generation)
	if errors.Is(err, sql.ErrNoRows) {
		return namespaceRoot{}, nil, errNamespaceRootMissing
	}
	if err != nil {
		return namespaceRoot{}, nil, err
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT relative_path, parent_path, name, kind, depth, logical_bytes,
		       recursive_bytes, file_count, dir_count, modified_at
		FROM namespace_entries
			WHERE root_id = ? AND generation = ? AND depth <= ?
		ORDER BY relative_path LIMIT ?`, rootID, root.generation, maxDepth, namespaceMaxTreeRows+1)
	if err != nil {
		return namespaceRoot{}, nil, err
	}
	defer rows.Close()
	var entries []namespaceEntry
	for rows.Next() {
		var entry namespaceEntry
		if err := rows.Scan(&entry.Path, &entry.ParentPath, &entry.Name, &entry.Kind, &entry.Depth,
			&entry.LogicalBytes, &entry.RecursiveBytes, &entry.FileCount, &entry.DirCount, &entry.ModifiedAt); err != nil {
			return namespaceRoot{}, nil, err
		}
		entries = append(entries, entry)
		if len(entries) > namespaceMaxTreeRows {
			return namespaceRoot{}, nil, errors.New("namespace tree exceeds row limit")
		}
	}
	return root, entries, rows.Err()
}

func (s *Server) namespaceRoots(w http.ResponseWriter, r *http.Request) {
	identity, status := s.authenticate(r)
	if status != http.StatusOK {
		writeError(w, status, http.StatusText(status))
		return
	}
	if s.namespace == nil {
		writeError(w, http.StatusServiceUnavailable, "namespace snapshot unavailable")
		return
	}
	roots, err := s.namespace.roots(r.Context())
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "namespace snapshot unavailable")
		return
	}
	allowed := s.allowedNamespaceRoots(identity)
	filtered := roots[:0]
	for _, root := range roots {
		if identity.Role == roleAdmin {
			filtered = append(filtered, root)
			continue
		}
		if _, ok := allowed[root.ID]; ok {
			filtered = append(filtered, root)
		}
	}
	payload, err := json.Marshal(map[string]any{"roots": filtered})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "response encoding failed")
		return
	}
	writeEnvelope(w, payload, s.namespaceSample(filtered))
}

func (s *Server) namespaceTree(w http.ResponseWriter, r *http.Request) {
	identity, status := s.authenticate(r)
	if status != http.StatusOK {
		writeError(w, status, http.StatusText(status))
		return
	}
	if s.namespace == nil {
		writeError(w, http.StatusServiceUnavailable, "namespace snapshot unavailable")
		return
	}
	rootID := r.URL.Query().Get("rootId")
	if !namespaceRootIDPattern.MatchString(rootID) {
		writeError(w, http.StatusBadRequest, "invalid rootId")
		return
	}
	if identity.Role != roleAdmin {
		if _, ok := s.allowedNamespaceRoots(identity)[rootID]; !ok {
			writeError(w, http.StatusForbidden, "namespace root is not authorized")
			return
		}
	}
	maxDepth := 3
	if raw := r.URL.Query().Get("maxDepth"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 3 {
			writeError(w, http.StatusBadRequest, "maxDepth must be between 1 and 3")
			return
		}
		maxDepth = parsed
	}
	root, entries, err := s.namespace.tree(r.Context(), rootID, maxDepth)
	if errors.Is(err, errNamespaceRootMissing) {
		writeError(w, http.StatusNotFound, "namespace root not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "namespace snapshot unavailable")
		return
	}
	payload, err := json.Marshal(map[string]any{"root": root, "maxDepth": maxDepth, "entries": entries})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "response encoding failed")
		return
	}
	writeEnvelope(w, payload, s.namespaceSample([]namespaceRoot{root}))
}

func (s *Server) allowedNamespaceRoots(identity identity) map[string]struct{} {
	result := make(map[string]struct{})
	user, ok := s.users[identity.Subject]
	if !ok || user.Disabled || user.Role != identity.Role {
		return result
	}
	for _, rootID := range user.NamespaceRoots {
		result[rootID] = struct{}{}
	}
	return result
}

func (s *Server) namespaceSample(roots []namespaceRoot) sampleMeta {
	now := s.config.Now().UTC()
	if s.config.Mode == "fixture" {
		return sampleMeta{Source: "fixture", CollectedAt: now.Format(time.RFC3339), Freshness: "fresh"}
	}
	oldest := now
	errorText := ""
	for _, root := range roots {
		collected, err := time.Parse(time.RFC3339, root.CollectedAt)
		if err != nil {
			return sampleMeta{Source: "namespace-sqlite", CollectedAt: root.CollectedAt, Freshness: "unavailable", Error: "invalid snapshot timestamp"}
		}
		if collected.Before(oldest) {
			oldest = collected
		}
		if root.Status != "ready" && errorText == "" {
			errorText = root.Error
		}
	}
	age := now.Sub(oldest).Seconds()
	if age < 0 {
		age = 0
	}
	freshness := "fresh"
	if len(roots) == 0 || age > namespaceFreshFor.Seconds() || errorText != "" {
		freshness = "stale"
	}
	return sampleMeta{
		Source:      "namespace-sqlite",
		CollectedAt: oldest.Format(time.RFC3339),
		AgeSeconds:  age,
		Freshness:   freshness,
		Error:       errorText,
	}
}
