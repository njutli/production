package portal

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func loginRequest(t *testing.T, handler http.Handler, username, password string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]string{"username": username, "password": password})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/api/v1/session", strings.NewReader(string(body)))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func requestWithCookie(handler http.Handler, method, path string, cookie *http.Cookie) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, nil)
	if cookie != nil {
		request.AddCookie(cookie)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func sessionCookie(t *testing.T, response *httptest.ResponseRecorder) *http.Cookie {
	t.Helper()
	result := response.Result()
	defer result.Body.Close()
	for _, cookie := range result.Cookies() {
		if cookie.Name == sessionCookieName {
			return cookie
		}
	}
	t.Fatal("session cookie missing")
	return nil
}

func TestLocalAdminLoginCreatesProtectedSession(t *testing.T) {
	handler := testServer(t)
	login := loginRequest(t, handler, "admin", "admin-test-password")
	if login.Code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", login.Code, login.Body.String())
	}
	cookie := sessionCookie(t, login)
	if !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/" {
		t.Fatalf("unsafe session cookie: %+v", cookie)
	}
	me := requestWithCookie(handler, http.MethodGet, "/api/v1/me", cookie)
	if me.Code != http.StatusOK || !strings.Contains(me.Body.String(), `"subject":"admin"`) || !strings.Contains(me.Body.String(), `"role":"ADMIN"`) {
		t.Fatalf("me status=%d body=%s", me.Code, me.Body.String())
	}
	overview := requestWithCookie(handler, http.MethodGet, "/api/v1/admin/overview", cookie)
	if overview.Code != http.StatusOK {
		t.Fatalf("admin overview status=%d body=%s", overview.Code, overview.Body.String())
	}
}

func TestUserSessionCannotAccessAdminAPI(t *testing.T) {
	handler := testServer(t)
	login := loginRequest(t, handler, "user", "user-test-password")
	if login.Code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", login.Code, login.Body.String())
	}
	cookie := sessionCookie(t, login)
	if got := requestWithCookie(handler, http.MethodGet, "/api/v1/admin/overview", cookie); got.Code != http.StatusForbidden {
		t.Fatalf("user admin status=%d body=%s", got.Code, got.Body.String())
	}
}

func TestSessionTamperAndExpiryAreRejected(t *testing.T) {
	handler := testServer(t)
	login := loginRequest(t, handler, "admin", "admin-test-password")
	cookie := sessionCookie(t, login)
	cookie.Value += "x"
	if got := requestWithCookie(handler, http.MethodGet, "/api/v1/me", cookie); got.Code != http.StatusUnauthorized {
		t.Fatalf("tampered session status=%d", got.Code)
	}

	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	config := withTestAuth(t, Config{
		Mode: "fixture", FixturesDir: "../../../fixtures", WebDir: "../../../web",
		AdminToken: "admin-test-token", UserToken: "user-test-token", SessionTTL: 15 * time.Minute,
		Now: func() time.Time { return now },
	})
	server, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	login = loginRequest(t, server.Handler(), "admin", "admin-test-password")
	cookie = sessionCookie(t, login)
	now = now.Add(16 * time.Minute)
	if got := requestWithCookie(server.Handler(), http.MethodGet, "/api/v1/me", cookie); got.Code != http.StatusUnauthorized {
		t.Fatalf("expired session status=%d", got.Code)
	}
}

func TestLoginRateLimitAndGenericFailure(t *testing.T) {
	handler := testServer(t)
	for attempt := 1; attempt <= 5; attempt++ {
		response := loginRequest(t, handler, "missing", "wrong-password-value")
		if response.Code != http.StatusUnauthorized || strings.Contains(response.Body.String(), "missing") {
			t.Fatalf("attempt=%d status=%d body=%s", attempt, response.Code, response.Body.String())
		}
	}
	blocked := loginRequest(t, handler, "admin", "admin-test-password")
	if blocked.Code != http.StatusTooManyRequests || blocked.Header().Get("Retry-After") == "" {
		t.Fatalf("blocked status=%d headers=%v", blocked.Code, blocked.Header())
	}
}

func TestLogoutClearsSessionAndSecurityHeaders(t *testing.T) {
	handler := testServer(t)
	login := loginRequest(t, handler, "admin", "admin-test-password")
	cookie := sessionCookie(t, login)
	logout := requestWithCookie(handler, http.MethodDelete, "/api/v1/session", cookie)
	if logout.Code != http.StatusNoContent {
		t.Fatalf("logout status=%d body=%s", logout.Code, logout.Body.String())
	}
	cleared := sessionCookie(t, logout)
	if cleared.MaxAge != -1 || !cleared.HttpOnly {
		t.Fatalf("cookie not cleared safely: %+v", cleared)
	}
	if logout.Header().Get("Content-Security-Policy") == "" || logout.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatalf("security headers missing: %v", logout.Header())
	}
	if got := request(t, handler, http.MethodPost, "/api/v1/admin/overview", "admin-test-token"); got.Code != http.StatusMethodNotAllowed {
		t.Fatalf("non-auth write status=%d", got.Code)
	}
}

func TestSecureCookieModeRejectsPlainHTTPLogin(t *testing.T) {
	_, filename, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", ".."))
	config := withTestAuth(t, Config{
		Mode: "fixture", FixturesDir: filepath.Join(root, "fixtures"), WebDir: filepath.Join(root, "web"),
		AdminToken: "admin-test-token", UserToken: "user-test-token", SecureCookies: true,
	})
	server, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	response := loginRequest(t, server.Handler(), "admin", "admin-test-password")
	if response.Code != http.StatusUpgradeRequired {
		t.Fatalf("plain HTTP login status=%d body=%s", response.Code, response.Body.String())
	}
}
