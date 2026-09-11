package namespacecollector

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"juicefs-cluster-portal/api/schema"

	_ "modernc.org/sqlite"
)

const (
	configVersion          = 1
	schemaVersion          = 1
	maxRoots               = 32
	maxSummaryRowsPerRoot  = 10000
	maxSummaryEntries      = 100
	maxSummaryOutputBytes  = 16 << 20
	maxSummaryErrorBytes   = 64 << 10
	defaultCollectionLimit = 15 * time.Second
)

var rootIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

type Config struct {
	Version int          `json:"version"`
	Roots   []RootConfig `json:"roots"`
}

type RootConfig struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Path        string `json:"path"`
}

type Options struct {
	DBPath             string
	JuiceFSBinary      string
	Config             Config
	CollectionTimeout  time.Duration
	AllowWritableRoots bool
	Now                func() time.Time
	Runner             SummaryRunner
}

type SummaryRunner interface {
	Summary(context.Context, string, string) ([]byte, error)
}

type ExecSummaryRunner struct{}

type summaryEntry struct {
	Path           string
	ParentPath     string
	Name           string
	Kind           string
	Depth          int
	RecursiveBytes int64
	FileCount      int64
	DirCount       int64
}

type summarySnapshot struct {
	TotalBytes int64
	FileCount  int64
	DirCount   int64
	Entries    []summaryEntry
}

type cappedBuffer struct {
	buffer bytes.Buffer
	limit  int
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	remaining := b.limit - b.buffer.Len()
	if remaining <= 0 {
		return 0, errors.New("command output limit exceeded")
	}
	if len(p) > remaining {
		_, _ = b.buffer.Write(p[:remaining])
		return remaining, errors.New("command output limit exceeded")
	}
	return b.buffer.Write(p)
}

func (b *cappedBuffer) Bytes() []byte  { return b.buffer.Bytes() }
func (b *cappedBuffer) String() string { return b.buffer.String() }

func (ExecSummaryRunner) Summary(ctx context.Context, binary, rootPath string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, binary, "summary", "--depth", "3", "--entries", strconv.Itoa(maxSummaryEntries), "--csv", rootPath)
	stdout := &cappedBuffer{limit: maxSummaryOutputBytes}
	stderr := &cappedBuffer{limit: maxSummaryErrorBytes}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return nil, fmt.Errorf("juicefs summary failed: %s", detail)
	}
	return append([]byte(nil), stdout.Bytes()...), nil
}

func LoadConfig(path string) (Config, error) {
	if !filepath.IsAbs(path) {
		return Config{}, errors.New("collector config path must be absolute")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read collector config: %w", err)
	}
	var config Config
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("decode collector config: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return Config{}, errors.New("collector config contains trailing data")
	}
	if err := validateConfig(config); err != nil {
		return Config{}, err
	}
	return config, nil
}

func validateConfig(config Config) error {
	if config.Version != configVersion {
		return fmt.Errorf("collector config version must be %d", configVersion)
	}
	if len(config.Roots) == 0 || len(config.Roots) > maxRoots {
		return fmt.Errorf("collector config must contain between 1 and %d roots", maxRoots)
	}
	ids := make(map[string]struct{}, len(config.Roots))
	paths := make(map[string]struct{}, len(config.Roots))
	for _, root := range config.Roots {
		if !rootIDPattern.MatchString(root.ID) {
			return fmt.Errorf("invalid root ID %q", root.ID)
		}
		if _, exists := ids[root.ID]; exists {
			return fmt.Errorf("duplicate root ID %q", root.ID)
		}
		ids[root.ID] = struct{}{}
		if root.DisplayName == "" || len([]rune(root.DisplayName)) > 128 {
			return fmt.Errorf("invalid display name for %q", root.ID)
		}
		for _, character := range root.DisplayName {
			if unicode.IsControl(character) {
				return fmt.Errorf("display name for %q contains control characters", root.ID)
			}
		}
		if !filepath.IsAbs(root.Path) || filepath.Clean(root.Path) != root.Path || root.Path == "/" {
			return fmt.Errorf("root path for %q must be a clean absolute non-root path", root.ID)
		}
		if _, exists := paths[root.Path]; exists {
			return fmt.Errorf("duplicate root path for %q", root.ID)
		}
		paths[root.Path] = struct{}{}
	}
	return nil
}

func Run(ctx context.Context, options Options) error {
	if err := validateConfig(options.Config); err != nil {
		return err
	}
	if !filepath.IsAbs(options.DBPath) {
		return errors.New("namespace database path must be absolute")
	}
	if options.CollectionTimeout == 0 {
		options.CollectionTimeout = defaultCollectionLimit
	}
	if options.CollectionTimeout < time.Second || options.CollectionTimeout > time.Minute {
		return errors.New("collection timeout must be between 1 second and 1 minute")
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Runner == nil {
		if err := validateExecutable(options.JuiceFSBinary); err != nil {
			return err
		}
		options.Runner = ExecSummaryRunner{}
	}
	store, err := openStore(options.DBPath)
	if err != nil {
		return err
	}
	defer store.Close()

	failures := make([]string, 0)
	for _, root := range options.Config.Roots {
		if err := validateRootPath(root.Path, options.AllowWritableRoots); err != nil {
			_ = store.markFailure(ctx, root.ID)
			failures = append(failures, fmt.Sprintf("%s: %v", root.ID, err))
			continue
		}
		collectionContext, cancel := context.WithTimeout(ctx, options.CollectionTimeout)
		output, runErr := options.Runner.Summary(collectionContext, options.JuiceFSBinary, root.Path)
		cancel()
		if runErr != nil {
			_ = store.markFailure(ctx, root.ID)
			failures = append(failures, fmt.Sprintf("%s: %v", root.ID, runErr))
			continue
		}
		snapshot, parseErr := parseSummary(output, root.DisplayName)
		if parseErr != nil {
			_ = store.markFailure(ctx, root.ID)
			failures = append(failures, fmt.Sprintf("%s: %v", root.ID, parseErr))
			continue
		}
		collectedAt := options.Now().UTC().Truncate(time.Second).Format(time.RFC3339)
		if err := store.replaceSnapshot(ctx, root, snapshot, collectedAt); err != nil {
			_ = store.markFailure(ctx, root.ID)
			failures = append(failures, fmt.Sprintf("%s: store snapshot: %v", root.ID, err))
		}
	}
	if len(failures) > 0 {
		sort.Strings(failures)
		return errors.New(strings.Join(failures, "; "))
	}
	return nil
}

func validateExecutable(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("JuiceFS binary path must be absolute")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("stat JuiceFS binary: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0111 == 0 {
		return errors.New("JuiceFS binary must be an executable regular non-symlink file")
	}
	return nil
}

func validateRootPath(path string, allowWritable bool) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("stat root: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("root must be a directory and not a symlink")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return fmt.Errorf("resolve root: %w", err)
	}
	if resolved != path {
		return errors.New("root path must not traverse symlinks")
	}
	if allowWritable {
		return nil
	}
	readOnly, err := pathIsOnReadOnlyMount(path)
	if err != nil {
		return err
	}
	if !readOnly {
		return errors.New("root is not on a read-only mount")
	}
	return nil
}

func pathIsOnReadOnlyMount(path string) (bool, error) {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false, fmt.Errorf("read mountinfo: %w", err)
	}
	return readOnlyFromMountInfo(path, string(data))
}

func readOnlyFromMountInfo(path, mountInfo string) (bool, error) {
	bestMount := ""
	bestReadOnly := false
	for _, line := range strings.Split(mountInfo, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}
		mountPoint, err := unescapeMountInfo(fields[4])
		if err != nil {
			continue
		}
		if path != mountPoint && !strings.HasPrefix(path, strings.TrimSuffix(mountPoint, "/")+"/") {
			continue
		}
		if len(mountPoint) < len(bestMount) {
			continue
		}
		bestMount = mountPoint
		bestReadOnly = optionPresent(fields[5], "ro")
	}
	if bestMount == "" {
		return false, errors.New("root mount could not be identified")
	}
	return bestReadOnly, nil
}

func unescapeMountInfo(value string) (string, error) {
	replacer := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`)
	result := replacer.Replace(value)
	if strings.Contains(result, `\0`) {
		return "", errors.New("unsupported mountinfo escape")
	}
	return result, nil
}

func optionPresent(options, expected string) bool {
	for _, option := range strings.Split(options, ",") {
		if option == expected {
			return true
		}
	}
	return false
}

func parseSummary(data []byte, rootDisplayName string) (summarySnapshot, error) {
	reader := csv.NewReader(bytes.NewReader(data))
	reader.FieldsPerRecord = 4
	header, err := reader.Read()
	if err != nil {
		return summarySnapshot{}, fmt.Errorf("read summary header: %w", err)
	}
	expectedHeader := []string{"PATH", "SIZE", "DIRS", "FILES"}
	for index := range expectedHeader {
		if header[index] != expectedHeader[index] {
			return summarySnapshot{}, errors.New("unexpected summary header")
		}
	}
	entries := make([]summaryEntry, 0)
	seen := make(map[string]struct{})
	var snapshot summarySnapshot
	rootFound := false
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return summarySnapshot{}, fmt.Errorf("read summary row: %w", err)
		}
		entry, err := parseSummaryRow(record, rootDisplayName)
		if err != nil {
			return summarySnapshot{}, err
		}
		if _, exists := seen[entry.Path]; exists {
			return summarySnapshot{}, fmt.Errorf("duplicate summary path %q", entry.Path)
		}
		seen[entry.Path] = struct{}{}
		entries = append(entries, entry)
		if len(entries) > maxSummaryRowsPerRoot {
			return summarySnapshot{}, fmt.Errorf("summary exceeds %d visible rows", maxSummaryRowsPerRoot)
		}
		if entry.Path == "/" {
			rootFound = true
			snapshot.TotalBytes = entry.RecursiveBytes
			snapshot.FileCount = entry.FileCount
			snapshot.DirCount = entry.DirCount
		}
	}
	if !rootFound {
		return summarySnapshot{}, errors.New("summary does not contain root row")
	}
	for _, entry := range entries {
		if entry.Path != "/" {
			if _, exists := seen[entry.ParentPath]; !exists {
				return summarySnapshot{}, fmt.Errorf("summary parent missing for %q", entry.Path)
			}
		}
	}
	visibleDirectories := int64(0)
	for _, entry := range entries {
		if entry.Kind == "directory" {
			visibleDirectories++
		}
	}
	if snapshot.DirCount < visibleDirectories {
		return summarySnapshot{}, errors.New("summary root directory count is smaller than returned tree")
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Path < entries[j].Path })
	snapshot.Entries = entries
	return snapshot, nil
}

func parseSummaryRow(record []string, rootDisplayName string) (summaryEntry, error) {
	rawPath := record[0]
	if !utf8.ValidString(rawPath) || strings.ContainsRune(rawPath, '\x00') {
		return summaryEntry{}, errors.New("summary contains invalid path encoding")
	}
	entry := summaryEntry{}
	if rawPath == "/" {
		entry.Path = "/"
		entry.ParentPath = ""
		entry.Name = rootDisplayName
		entry.Kind = "directory"
	} else {
		if strings.HasPrefix(rawPath, "/") {
			return summaryEntry{}, fmt.Errorf("invalid summary path %q", rawPath)
		}
		isDirectory := strings.HasSuffix(rawPath, "/")
		trimmed := strings.TrimSuffix(rawPath, "/")
		parts := strings.Split(trimmed, "/")
		if len(parts) == 0 || len(parts) > 3 {
			return summaryEntry{}, fmt.Errorf("summary path depth outside contract: %q", rawPath)
		}
		for _, part := range parts {
			if part == "" || part == "." || part == ".." {
				return summaryEntry{}, fmt.Errorf("unsafe summary path %q", rawPath)
			}
		}
		entry.Path = "/" + strings.Join(parts, "/")
		entry.Name = parts[len(parts)-1]
		switch {
		case entry.Name == "...":
			entry.Kind = "aggregate"
			entry.Name = "其余项（聚合）"
		case isDirectory:
			entry.Kind = "directory"
		default:
			entry.Kind = "file"
		}
		entry.Depth = len(parts)
		if len(parts) == 1 {
			entry.ParentPath = "/"
		} else {
			entry.ParentPath = "/" + strings.Join(parts[:len(parts)-1], "/")
		}
	}
	values := []*int64{&entry.RecursiveBytes, &entry.DirCount, &entry.FileCount}
	for index, destination := range values {
		value, err := strconv.ParseInt(record[index+1], 10, 64)
		if err != nil || value < 0 {
			return summaryEntry{}, fmt.Errorf("invalid numeric field for %q", rawPath)
		}
		*destination = value
	}
	if entry.Kind == "directory" && entry.DirCount < 1 {
		return summaryEntry{}, fmt.Errorf("directory count must include self for %q", rawPath)
	}
	if entry.Kind == "file" && (entry.DirCount != 0 || entry.FileCount != 1) {
		return summaryEntry{}, fmt.Errorf("invalid file counts for %q", rawPath)
	}
	if entry.Kind == "aggregate" && entry.DirCount == 0 && entry.FileCount == 0 {
		return summaryEntry{}, fmt.Errorf("empty aggregate for %q", rawPath)
	}
	return entry, nil
}

type store struct {
	db *sql.DB
}

func openStore(path string) (*store, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("namespace database path must be absolute")
	}
	parent := filepath.Dir(path)
	info, err := os.Lstat(parent)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("namespace database parent must be an existing non-symlink directory")
	}
	if existing, err := os.Lstat(path); err == nil {
		if !existing.Mode().IsRegular() || existing.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("namespace database must be a regular non-symlink file")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("stat namespace database: %w", err)
	}
	dsn := (&url.URL{Scheme: "file", Path: path}).String() + "?mode=rwc&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open namespace database: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("enable namespace WAL: %w", err)
	}
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		db.Close()
		return nil, fmt.Errorf("read namespace schema version: %w", err)
	}
	if version == 0 {
		if _, err := db.Exec(schema.NamespaceV1); err != nil {
			db.Close()
			return nil, fmt.Errorf("initialize namespace schema: %w", err)
		}
		version = schemaVersion
	}
	if version != schemaVersion {
		db.Close()
		return nil, fmt.Errorf("namespace schema version %d, expected %d", version, schemaVersion)
	}
	if err := os.Chmod(path, 0640); err != nil {
		db.Close()
		return nil, fmt.Errorf("set namespace database permissions: %w", err)
	}
	return &store{db: db}, nil
}

func (s *store) Close() error { return s.db.Close() }

func (s *store) replaceSnapshot(ctx context.Context, root RootConfig, snapshot summarySnapshot, collectedAt string) error {
	transaction, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer transaction.Rollback()
	var previousGeneration int64
	err = transaction.QueryRowContext(ctx, "SELECT current_generation FROM snapshot_roots WHERE root_id = ?", root.ID).Scan(&previousGeneration)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	newGeneration := previousGeneration + 1
	if newGeneration < 1 {
		newGeneration = 1
	}
	_, err = transaction.ExecContext(ctx, `
		INSERT INTO snapshot_roots
		(root_id, display_name, virtual_path, current_generation, logical_bytes, file_count, dir_count, collected_at, status, error)
		VALUES (?, ?, '/', ?, ?, ?, ?, ?, 'ready', '')
		ON CONFLICT(root_id) DO UPDATE SET
			display_name=excluded.display_name,
			virtual_path='/',
			current_generation=excluded.current_generation,
			logical_bytes=excluded.logical_bytes,
			file_count=excluded.file_count,
			dir_count=excluded.dir_count,
			collected_at=excluded.collected_at,
			status='ready',
			error=''`, root.ID, root.DisplayName, newGeneration, snapshot.TotalBytes,
		snapshot.FileCount, snapshot.DirCount, collectedAt)
	if err != nil {
		return err
	}
	statement, err := transaction.PrepareContext(ctx, `
		INSERT INTO namespace_entries
		(root_id, generation, relative_path, parent_path, name, kind, depth, logical_bytes,
		 recursive_bytes, file_count, dir_count, modified_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '')`)
	if err != nil {
		return err
	}
	for _, entry := range snapshot.Entries {
		logicalBytes := int64(0)
		if entry.Kind == "file" {
			logicalBytes = entry.RecursiveBytes
		}
		if _, err := statement.ExecContext(ctx, root.ID, newGeneration, entry.Path, entry.ParentPath,
			entry.Name, entry.Kind, entry.Depth, logicalBytes, entry.RecursiveBytes, entry.FileCount, entry.DirCount); err != nil {
			statement.Close()
			return err
		}
	}
	if err := statement.Close(); err != nil {
		return err
	}
	if _, err := transaction.ExecContext(ctx,
		"DELETE FROM namespace_entries WHERE root_id = ? AND generation <> ?", root.ID, newGeneration); err != nil {
		return err
	}
	return transaction.Commit()
}

func (s *store) markFailure(ctx context.Context, rootID string) error {
	_, err := s.db.ExecContext(ctx, "UPDATE snapshot_roots SET status = 'failed', error = 'collector failed' WHERE root_id = ?", rootID)
	return err
}
