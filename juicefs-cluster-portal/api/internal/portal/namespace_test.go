package portal

import (
	"context"
	"database/sql"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"juicefs-cluster-portal/api/internal/namespacecollector"
)

type portalSummaryRunner struct {
	output []byte
}

func (r *portalSummaryRunner) Summary(context.Context, string, string) ([]byte, error) {
	return append([]byte(nil), r.output...), nil
}

func TestNamespaceAPIFiltersRootsByAuthenticatedUser(t *testing.T) {
	handler := testServer(t)
	login := loginRequest(t, handler, "user", "user-test-password")
	cookie := sessionCookie(t, login)

	roots := requestWithCookie(handler, http.MethodGet, "/api/v1/usage/roots", cookie)
	if roots.Code != http.StatusOK || !strings.Contains(roots.Body.String(), `"id":"team-a"`) {
		t.Fatalf("roots status=%d body=%s", roots.Code, roots.Body.String())
	}
	if strings.Contains(roots.Body.String(), `"id":"shared-readonly"`) {
		t.Fatalf("unauthorized root leaked: %s", roots.Body.String())
	}

	tree := requestWithCookie(handler, http.MethodGet, "/api/v1/usage/tree?rootId=team-a&maxDepth=3", cookie)
	if tree.Code != http.StatusOK || !strings.Contains(tree.Body.String(), `"path":"/models/checkpoints/weekly"`) {
		t.Fatalf("tree status=%d body=%s", tree.Code, tree.Body.String())
	}
	forbidden := requestWithCookie(handler, http.MethodGet, "/api/v1/usage/tree?rootId=shared-readonly", cookie)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("forbidden root status=%d body=%s", forbidden.Code, forbidden.Body.String())
	}
}

func TestNamespaceAdminCanReadAllRootsAndInputIsBounded(t *testing.T) {
	handler := testServer(t)
	roots := request(t, handler, http.MethodGet, "/api/v1/usage/roots", "admin-test-token")
	if roots.Code != http.StatusOK || !strings.Contains(roots.Body.String(), `"id":"team-a"`) ||
		!strings.Contains(roots.Body.String(), `"id":"shared-readonly"`) {
		t.Fatalf("admin roots status=%d body=%s", roots.Code, roots.Body.String())
	}
	if got := request(t, handler, http.MethodGet, "/api/v1/usage/tree?rootId=team-a&maxDepth=4", "admin-test-token"); got.Code != http.StatusBadRequest {
		t.Fatalf("unbounded depth status=%d body=%s", got.Code, got.Body.String())
	}
	if got := request(t, handler, http.MethodGet, "/api/v1/usage/tree?rootId=missing", "admin-test-token"); got.Code != http.StatusNotFound {
		t.Fatalf("missing root status=%d body=%s", got.Code, got.Body.String())
	}
	if got := request(t, handler, http.MethodGet, "/api/v1/usage/tree?rootId=../escape", "admin-test-token"); got.Code != http.StatusBadRequest {
		t.Fatalf("unsafe root status=%d body=%s", got.Code, got.Body.String())
	}
}

func TestSQLiteNamespaceSourceIsReadOnlyAndUsesTreeIndex(t *testing.T) {
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	apiRoot := filepath.Clean(filepath.Join(filepath.Dir(filename), "..", ".."))
	schema, err := os.ReadFile(filepath.Join(apiRoot, "schema", "namespace-v1.sql"))
	if err != nil {
		t.Fatal(err)
	}
	dbPath := filepath.Join(t.TempDir(), "namespace.db")
	writer, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Exec(string(schema)); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Exec(`
		INSERT INTO snapshot_roots
		(root_id, display_name, virtual_path, current_generation, logical_bytes, file_count, dir_count, collected_at, status, error)
		VALUES ('team-a', 'Team A', '/', 7, 8192, 1, 2, '2026-09-10T12:00:00Z', 'ready', '');
		INSERT INTO namespace_entries
		(root_id, generation, relative_path, parent_path, name, kind, depth, logical_bytes, recursive_bytes, file_count, dir_count, modified_at)
		VALUES
		('team-a', 7, '/', '', 'Team A', 'directory', 0, 4096, 8192, 1, 2, ''),
		('team-a', 7, '/data', '/', 'data', 'directory', 1, 4096, 4096, 1, 1, ''),
		('team-a', 7, '/large.bin', '/', 'large.bin', 'file', 1, 2048, 2048, 1, 0, ''),
		('team-a', 7, '/...', '/', '其余项（聚合）', 'aggregate', 1, 0, 1024, 17, 3, '');`); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	source, err := newSQLiteNamespaceSource(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer source.db.Close()
	root, entries, err := source.tree(context.Background(), "team-a", 3)
	if err != nil || root.generation != 7 || len(entries) != 4 || entries[1].Kind != "aggregate" || entries[3].Kind != "file" {
		t.Fatalf("root=%+v entries=%+v err=%v", root, entries, err)
	}
	if _, err := source.db.Exec(`INSERT INTO snapshot_roots(root_id) VALUES ('write')`); err == nil {
		t.Fatal("read-only namespace connection accepted a write")
	}

	var id, parent, unused int
	var detail string
	err = source.db.QueryRow(`EXPLAIN QUERY PLAN
		SELECT relative_path FROM namespace_entries
			WHERE root_id = ? AND generation = ? AND depth <= ?
		ORDER BY relative_path LIMIT ?`, "team-a", 7, 3, namespaceMaxTreeRows+1).Scan(&id, &parent, &unused, &detail)
	if err != nil || !strings.Contains(detail, "idx_namespace_entries_tree") {
		t.Fatalf("query plan detail=%q err=%v", detail, err)
	}
}

func TestSQLiteNamespaceSourceSeesCollectorGenerationSwitch(t *testing.T) {
	rootPath := t.TempDir()
	dbPath := filepath.Join(t.TempDir(), "namespace.db")
	runner := &portalSummaryRunner{output: []byte("PATH,SIZE,DIRS,FILES\n/,100,2,3\na/,40,1,1\nbig.bin,30,0,1\n...,30,0,1\n")}
	options := namespacecollector.Options{
		DBPath: dbPath,
		Config: namespacecollector.Config{Version: 1, Roots: []namespacecollector.RootConfig{{
			ID: "team-a", DisplayName: "Team A", Path: rootPath,
		}}},
		AllowWritableRoots: true,
		Runner:             runner,
		CollectionTimeout:  time.Second,
		Now:                func() time.Time { return time.Date(2026, 9, 11, 4, 0, 0, 0, time.UTC) },
	}
	if err := namespacecollector.Run(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	source, err := newSQLiteNamespaceSource(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer source.db.Close()
	root, entries, err := source.tree(context.Background(), "team-a", 3)
	if err != nil || root.LogicalBytes != 100 || len(entries) != 4 || entries[1].Kind != "aggregate" || entries[3].Kind != "file" {
		t.Fatalf("initial root=%+v entries=%d err=%v", root, len(entries), err)
	}

	runner.output = []byte("PATH,SIZE,DIRS,FILES\n/,200,2,5\na/,80,1,2\nbig.bin,70,0,1\n...,50,0,2\n")
	options.Now = func() time.Time { return time.Date(2026, 9, 11, 4, 1, 0, 0, time.UTC) }
	if err := namespacecollector.Run(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	root, entries, err = source.tree(context.Background(), "team-a", 3)
	if err != nil || root.LogicalBytes != 200 || root.generation != 2 || len(entries) != 4 || entries[2].RecursiveBytes != 80 {
		t.Fatalf("refreshed root=%+v entries=%+v err=%v", root, entries, err)
	}
}
