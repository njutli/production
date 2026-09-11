package namespacecollector

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type sequenceRunner struct {
	outputs [][]byte
	errors  []error
	calls   int
}

func (r *sequenceRunner) Summary(context.Context, string, string) ([]byte, error) {
	index := r.calls
	r.calls++
	if index < len(r.errors) && r.errors[index] != nil {
		return nil, r.errors[index]
	}
	if index >= len(r.outputs) {
		return nil, errors.New("unexpected summary call")
	}
	return r.outputs[index], nil
}

func TestRunAtomicallyReplacesGenerationAndKeepsLastSuccessOnFailure(t *testing.T) {
	rootPath := t.TempDir()
	dbPath := filepath.Join(t.TempDir(), "namespace.db")
	config := Config{Version: 1, Roots: []RootConfig{{ID: "team-a", DisplayName: "Team A", Path: rootPath}}}
	first := []byte("PATH,SIZE,DIRS,FILES\n/,100,2,3\na/,40,1,1\n")
	second := []byte("PATH,SIZE,DIRS,FILES\n/,200,2,5\na/,80,1,2\n")
	runner := &sequenceRunner{outputs: [][]byte{first, second}}
	baseOptions := Options{
		DBPath:             dbPath,
		Config:             config,
		AllowWritableRoots: true,
		Runner:             runner,
		CollectionTimeout:  time.Second,
		Now:                func() time.Time { return time.Date(2026, 9, 11, 4, 0, 0, 0, time.UTC) },
	}
	if err := Run(context.Background(), baseOptions); err != nil {
		t.Fatal(err)
	}
	baseOptions.Now = func() time.Time { return time.Date(2026, 9, 11, 4, 1, 0, 0, time.UTC) }
	if err := Run(context.Background(), baseOptions); err != nil {
		t.Fatal(err)
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var generation, totalBytes, fileCount int64
	var status, collectedAt string
	if err := db.QueryRow(`SELECT current_generation, logical_bytes, file_count, status, collected_at
		FROM snapshot_roots WHERE root_id='team-a'`).Scan(&generation, &totalBytes, &fileCount, &status, &collectedAt); err != nil {
		t.Fatal(err)
	}
	if generation != 2 || totalBytes != 200 || fileCount != 5 || status != "ready" || collectedAt != "2026-09-11T04:01:00Z" {
		t.Fatalf("unexpected current snapshot: generation=%d bytes=%d files=%d status=%s collected=%s",
			generation, totalBytes, fileCount, status, collectedAt)
	}
	var oldRows, currentRows int
	if err := db.QueryRow("SELECT count(*) FROM namespace_entries WHERE root_id='team-a' AND generation=1").Scan(&oldRows); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow("SELECT count(*) FROM namespace_entries WHERE root_id='team-a' AND generation=2").Scan(&currentRows); err != nil {
		t.Fatal(err)
	}
	if oldRows != 0 || currentRows != 2 {
		t.Fatalf("oldRows=%d currentRows=%d", oldRows, currentRows)
	}

	baseOptions.Runner = &sequenceRunner{errors: []error{errors.New("injected collection failure")}}
	if err := Run(context.Background(), baseOptions); err == nil {
		t.Fatal("expected failed collection")
	}
	var afterGeneration, afterBytes int64
	var afterStatus, afterError string
	if err := db.QueryRow(`SELECT current_generation, logical_bytes, status, error
		FROM snapshot_roots WHERE root_id='team-a'`).Scan(&afterGeneration, &afterBytes, &afterStatus, &afterError); err != nil {
		t.Fatal(err)
	}
	if afterGeneration != 2 || afterBytes != 200 || afterStatus != "failed" || afterError != "collector failed" {
		t.Fatalf("failure changed last success: generation=%d bytes=%d status=%s error=%s",
			afterGeneration, afterBytes, afterStatus, afterError)
	}
}

func TestParseSummaryRejectsUnsafeOrIncompleteTrees(t *testing.T) {
	tests := []string{
		"PATH,SIZE,DIRS,FILES\n../escape/,1,1,0\n",
		"PATH,SIZE,DIRS,FILES\n/,1,2,0\na/b/,1,1,0\n",
		"PATH,SIZE,DIRS,FILES\n/,1,1,0\n/,1,1,0\n",
		"PATH,BYTES,DIRS,FILES\n/,1,1,0\n",
	}
	for _, input := range tests {
		if _, err := parseSummary([]byte(input), "root"); err == nil {
			t.Fatalf("accepted invalid summary: %q", input)
		}
	}
}

func TestParseSummaryAcceptsFilesAndOmittedAggregate(t *testing.T) {
	input := []byte("PATH,SIZE,DIRS,FILES\n/,1000,2,102\na/,600,1,50\nbig.bin,300,0,1\n...,100,1,51\n")
	snapshot, err := parseSummary(input, "root")
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Entries) != 4 {
		t.Fatalf("entries=%d", len(snapshot.Entries))
	}
	kinds := make(map[string]string)
	for _, entry := range snapshot.Entries {
		kinds[entry.Path] = entry.Kind
	}
	if kinds["/"] != "directory" || kinds["/a"] != "directory" || kinds["/big.bin"] != "file" || kinds["/..."] != "aggregate" {
		t.Fatalf("unexpected kinds: %#v", kinds)
	}
	for _, entry := range snapshot.Entries {
		if entry.Path == "/..." && (entry.Name != "其余项（聚合）" || entry.RecursiveBytes != 100 || entry.DirCount != 1 || entry.FileCount != 51) {
			t.Fatalf("unexpected aggregate: %+v", entry)
		}
	}
}

func TestLoadConfigRejectsUnknownFieldsAndDuplicateRoots(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "roots.json")
	if err := os.WriteFile(path, []byte(`{"version":1,"roots":[{"id":"a","displayName":"A","path":"/mnt/a","extra":true}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unknown field error=%v", err)
	}
	if err := os.WriteFile(path, []byte(`{"version":1,"roots":[{"id":"a","displayName":"A","path":"/mnt/a"},{"id":"a","displayName":"B","path":"/mnt/b"}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "duplicate root ID") {
		t.Fatalf("duplicate root error=%v", err)
	}
}

func TestReadOnlyFromMountInfoUsesDeepestMount(t *testing.T) {
	mountInfo := strings.Join([]string{
		"1 0 8:1 / / rw,relatime - ext4 /dev/root rw",
		"2 1 0:42 / /mnt/portal\\040data ro,nosuid,nodev - fuse.juicefs JuiceFS:prod ro",
		"",
	}, "\n")
	readOnly, err := readOnlyFromMountInfo("/mnt/portal data/team-a", mountInfo)
	if err != nil || !readOnly {
		t.Fatalf("readOnly=%t err=%v", readOnly, err)
	}
	readOnly, err = readOnlyFromMountInfo("/tmp", mountInfo)
	if err != nil || readOnly {
		t.Fatalf("root fallback readOnly=%t err=%v", readOnly, err)
	}
}
