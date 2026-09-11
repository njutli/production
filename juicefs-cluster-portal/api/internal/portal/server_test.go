package portal

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	testUsersOnce sync.Once
	testUsers     []LocalUser
	testUsersErr  error
)

func withTestAuth(t *testing.T, config Config) Config {
	t.Helper()
	testUsersOnce.Do(func() {
		adminHash, err := HashPassword("admin-test-password")
		if err != nil {
			testUsersErr = err
			return
		}
		userHash, err := HashPassword("user-test-password")
		if err != nil {
			testUsersErr = err
			return
		}
		testUsers = []LocalUser{
			{Username: "admin", Role: roleAdmin, PasswordHash: adminHash},
			{Username: "user", Role: roleUser, PasswordHash: userHash, NamespaceRoots: []string{"team-a"}},
		}
	})
	if testUsersErr != nil {
		t.Fatal(testUsersErr)
	}
	config.LocalUsers = testUsers
	config.SessionSecret = []byte("test-session-secret-at-least-32-bytes")
	return config
}

func testServer(t *testing.T) http.Handler {
	t.Helper()
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", ".."))
	server, err := New(withTestAuth(t, Config{
		FixturesDir: filepath.Join(root, "fixtures"),
		WebDir:      filepath.Join(root, "web"),
		AdminToken:  "admin-test-token",
		UserToken:   "user-test-token",
		Now: func() time.Time {
			return time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
		},
	}))
	if err != nil {
		t.Fatal(err)
	}
	return server.Handler()
}

func request(t *testing.T, handler http.Handler, method, path, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func mockPrometheusClient(response func(*http.Request) (int, string)) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		status, body := response(request)
		return &http.Response{
			StatusCode: status,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(body)),
			Request:    request,
		}, nil
	})}
}

func TestHealthDoesNotRequireAuthentication(t *testing.T) {
	response := request(t, testServer(t), http.MethodGet, "/api/v1/health", "")
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestAdminEndpointRejectsUnauthenticatedAndUser(t *testing.T) {
	handler := testServer(t)
	if got := request(t, handler, http.MethodGet, "/api/v1/admin/overview", "").Code; got != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status=%d", got)
	}
	if got := request(t, handler, http.MethodGet, "/api/v1/admin/overview", "user-test-token").Code; got != http.StatusForbidden {
		t.Fatalf("user status=%d", got)
	}
}

func TestAdminFixtureIncludesFreshness(t *testing.T) {
	response := request(t, testServer(t), http.MethodGet, "/api/v1/admin/overview", "admin-test-token")
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Data   json.RawMessage `json:"data"`
		Sample sampleMeta      `json:"sample"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Data) == 0 || body.Sample.Freshness != "fresh" || body.Sample.Source != "fixture" {
		t.Fatalf("unexpected response: %+v", body.Sample)
	}
}

func TestDiskLookupIsBoundedToFixtureNodes(t *testing.T) {
	handler := testServer(t)
	if got := request(t, handler, http.MethodGet, "/api/v1/admin/nodes/152/disks", "admin-test-token").Code; got != http.StatusOK {
		t.Fatalf("known node status=%d", got)
	}
	if got := request(t, handler, http.MethodGet, "/api/v1/admin/nodes/999/disks", "admin-test-token").Code; got != http.StatusNotFound {
		t.Fatalf("unknown node status=%d", got)
	}
}

func TestTimeseriesAllowsOnlyWhitelistedMetric(t *testing.T) {
	handler := testServer(t)
	valid := "/api/v1/admin/timeseries?metric=jfs.fuse.read_bps&from=2026-09-10T11:00:00Z&to=2026-09-10T12:00:00Z&step=15"
	if got := request(t, handler, http.MethodGet, valid, "admin-test-token").Code; got != http.StatusOK {
		t.Fatalf("valid metric status=%d", got)
	}
	invalid := strings.Replace(valid, "jfs.fuse.read_bps", "arbitrary.promql", 1)
	if got := request(t, handler, http.MethodGet, invalid, "admin-test-token").Code; got != http.StatusBadRequest {
		t.Fatalf("invalid metric status=%d", got)
	}
}

func TestAPIRejectsWrites(t *testing.T) {
	response := request(t, testServer(t), http.MethodPost, "/api/v1/admin/overview", "admin-test-token")
	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status=%d", response.Code)
	}
}

func TestLiveModeNeverServesFixtureData(t *testing.T) {
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", ".."))
	server, err := New(withTestAuth(t, Config{
		Mode:        "live",
		FixturesDir: filepath.Join(root, "fixtures"),
		WebDir:      filepath.Join(root, "web"),
		AdminToken:  "admin-test-token",
		UserToken:   "user-test-token",
	}))
	if err != nil {
		t.Fatal(err)
	}
	response := request(t, server.Handler(), http.MethodGet, "/api/v1/admin/overview", "admin-test-token")
	if response.Code != http.StatusServiceUnavailable || strings.Contains(response.Body.String(), "juicefsLogicalReadBps") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestStaticDashboardIsServed(t *testing.T) {
	response := request(t, testServer(t), http.MethodGet, "/", "")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "JuiceFS 集群监控") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestEveryFixtureIsValidJSON(t *testing.T) {
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	fixturesDir := filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", "..", "fixtures"))
	entries, err := os.ReadDir(fixturesDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(fixturesDir, entry.Name()))
		if err != nil {
			t.Errorf("%s: %v", entry.Name(), err)
			continue
		}
		if !json.Valid(data) {
			t.Errorf("%s is not valid JSON", entry.Name())
		}
	}
}

func TestEveryFixtureRouteServesReadOnlyEnvelope(t *testing.T) {
	handler := testServer(t)
	for path := range fixtureByPath {
		response := request(t, handler, http.MethodGet, path, "admin-test-token")
		if response.Code != http.StatusOK {
			t.Errorf("%s: status=%d body=%s", path, response.Code, response.Body.String())
		}
	}
}

func TestLiveRoutesUsePrometheusAndNeverFixtures(t *testing.T) {
	prometheus := mockPrometheusClient(func(r *http.Request) (int, string) {
		resultType := "vector"
		if r.URL.Path == "/api/v1/query_range" {
			resultType = "matrix"
		}
		return http.StatusOK, fmt.Sprintf(`{"status":"success","data":{"resultType":%q,"result":[]}}`, resultType)
	})

	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", ".."))
	server, err := New(withTestAuth(t, Config{
		Mode:          "live",
		FixturesDir:   filepath.Join(root, "fixtures"),
		WebDir:        filepath.Join(root, "web"),
		AdminToken:    "admin-test-token",
		UserToken:     "user-test-token",
		PrometheusURL: "http://127.0.0.1:9090",
		HTTPClient:    prometheus,
	}))
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	for path := range fixtureByPath {
		response := request(t, handler, http.MethodGet, path, "admin-test-token")
		if response.Code != http.StatusOK {
			t.Fatalf("%s: status=%d body=%s", path, response.Code, response.Body.String())
		}
		if strings.Contains(response.Body.String(), "fixture") {
			t.Fatalf("%s leaked fixture data: %s", path, response.Body.String())
		}
	}
	response := request(t, handler, http.MethodGet, "/api/v1/admin/nodes/150/disks", "admin-test-token")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "prometheus") {
		t.Fatalf("live disks status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestLiveCacheBecomesStaleWhenPrometheusFails(t *testing.T) {
	fail := false
	prometheus := mockPrometheusClient(func(_ *http.Request) (int, string) {
		if fail {
			return http.StatusServiceUnavailable, "unavailable"
		}
		return http.StatusOK, `{"status":"success","data":{"resultType":"vector","result":[]}}`
	})

	_, filename, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", ".."))
	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	server, err := New(withTestAuth(t, Config{
		Mode: "live", FixturesDir: filepath.Join(root, "fixtures"), WebDir: filepath.Join(root, "web"),
		AdminToken: "admin-test-token", UserToken: "user-test-token", PrometheusURL: "http://127.0.0.1:9090",
		HTTPClient: prometheus,
		Now:        func() time.Time { return now },
	}))
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	if got := request(t, handler, http.MethodGet, "/api/v1/admin/overview", "admin-test-token"); got.Code != http.StatusOK {
		t.Fatalf("initial status=%d body=%s", got.Code, got.Body.String())
	}
	fail = true
	now = now.Add(9 * time.Second)
	response := request(t, handler, http.MethodGet, "/api/v1/admin/overview", "admin-test-token")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"freshness":"stale"`) {
		t.Fatalf("cached status=%d body=%s", response.Code, response.Body.String())
	}
}
