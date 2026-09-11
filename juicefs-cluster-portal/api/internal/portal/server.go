package portal

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	roleAdmin = "ADMIN"
	roleUser  = "USER"
)

var errNodeNotFound = errors.New("node not found")

var fixtureByPath = map[string]string{
	"/api/v1/admin/overview":        "overview.json",
	"/api/v1/admin/topology":        "topology.json",
	"/api/v1/admin/nodes":           "nodes.json",
	"/api/v1/admin/juicefs/clients": "clients.json",
	"/api/v1/admin/tikv":            "tikv.json",
	"/api/v1/admin/ceph":            "ceph.json",
	"/api/v1/admin/usage":           "usage.json",
	"/api/v1/admin/alerts":          "alerts.json",
}

var allowedTimeseries = map[string]struct{}{
	"jfs.fuse.read_bps":      {},
	"jfs.fuse.write_bps":     {},
	"ceph.pool.read_bps":     {},
	"ceph.pool.write_bps":    {},
	"node.network.rx_bps":    {},
	"node.network.tx_bps":    {},
	"tikv.scheduler.latency": {},
}

type Config struct {
	Mode              string
	FixturesDir       string
	WebDir            string
	AdminToken        string
	UserToken         string
	UsersFile         string
	SessionSecretFile string
	SessionTTL        time.Duration
	SecureCookies     bool
	LocalUsers        []LocalUser
	SessionSecret     []byte
	PrometheusURL     string
	NamespaceDBPath   string
	HTTPClient        *http.Client
	Now               func() time.Time
}

type Server struct {
	config            Config
	live              *liveSource
	namespace         namespaceSource
	users             map[string]LocalUser
	sessionSecret     []byte
	dummyPasswordHash string
	loginLimiter      *loginLimiter
	loginSlots        chan struct{}
}

type sampleMeta struct {
	Source      string  `json:"source"`
	CollectedAt string  `json:"collectedAt"`
	AgeSeconds  float64 `json:"ageSeconds"`
	Freshness   string  `json:"freshness"`
	Error       string  `json:"error,omitempty"`
}

type envelope struct {
	Data   json.RawMessage `json:"data"`
	Sample sampleMeta      `json:"sample"`
}

func New(config Config) (*Server, error) {
	if config.Mode == "" {
		config.Mode = "fixture"
	}
	if config.Mode != "fixture" && config.Mode != "live" {
		return nil, errors.New("mode must be fixture or live")
	}
	if config.FixturesDir == "" || config.WebDir == "" {
		return nil, errors.New("fixture and web directories are required")
	}
	if config.AdminToken == "" || config.UserToken == "" {
		return nil, errors.New("admin and user tokens are required")
	}
	if config.AdminToken == config.UserToken {
		return nil, errors.New("admin and user tokens must differ")
	}
	if config.SessionTTL == 0 {
		config.SessionTTL = defaultSessionTTL
	}
	if config.SessionTTL < 15*time.Minute || config.SessionTTL > 24*time.Hour {
		return nil, errors.New("session TTL must be between 15 minutes and 24 hours")
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	users := make(map[string]LocalUser)
	if len(config.LocalUsers) > 0 {
		for _, user := range config.LocalUsers {
			users[user.Username] = user
		}
	} else {
		if config.UsersFile == "" {
			return nil, errors.New("users file is required")
		}
		loaded, err := loadUsers(config.UsersFile)
		if err != nil {
			return nil, err
		}
		users = loaded
	}
	sessionSecret := config.SessionSecret
	if len(sessionSecret) == 0 {
		if config.SessionSecretFile == "" {
			return nil, errors.New("session secret file is required")
		}
		loaded, err := loadSessionSecret(config.SessionSecretFile)
		if err != nil {
			return nil, err
		}
		sessionSecret = loaded
	}
	if len(sessionSecret) < 32 {
		return nil, errors.New("session secret must contain at least 32 bytes")
	}
	var dummyPasswordHash string
	for _, user := range users {
		dummyPasswordHash = user.PasswordHash
		break
	}
	if dummyPasswordHash == "" {
		return nil, errors.New("at least one local user is required")
	}
	server := &Server{
		config: config, users: users, sessionSecret: append([]byte(nil), sessionSecret...),
		dummyPasswordHash: dummyPasswordHash, loginLimiter: newLoginLimiter(), loginSlots: make(chan struct{}, 2),
	}
	if config.Mode == "live" {
		if config.PrometheusURL == "" {
			config.PrometheusURL = "http://127.0.0.1:9090"
			server.config.PrometheusURL = config.PrometheusURL
		}
		live, err := newLiveSource(config.PrometheusURL, config.HTTPClient, config.Now)
		if err != nil {
			return nil, err
		}
		server.live = live
	}
	if config.Mode == "fixture" {
		namespace, err := newFixtureNamespaceSource(filepath.Join(config.FixturesDir, "namespace.json"))
		if err != nil {
			return nil, err
		}
		server.namespace = namespace
	} else if config.NamespaceDBPath != "" {
		namespace, err := newSQLiteNamespaceSource(config.NamespaceDBPath)
		if err != nil {
			return nil, err
		}
		server.namespace = namespace
	}
	return server, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/health", s.health)
	mux.HandleFunc("/api/v1/me", s.me)
	mux.HandleFunc("/api/v1/session", s.session)
	mux.HandleFunc("/api/v1/usage/roots", s.namespaceRoots)
	mux.HandleFunc("/api/v1/usage/tree", s.namespaceTree)
	mux.HandleFunc("/api/v1/admin/nodes/", s.requireAdmin(s.disks))
	mux.HandleFunc("/api/v1/admin/timeseries", s.requireAdmin(s.timeseries))
	for path, fixtureName := range fixtureByPath {
		path, fixtureName := path, fixtureName
		key := strings.TrimSuffix(strings.TrimPrefix(path, "/api/v1/admin/"), "/")
		if key == "juicefs/clients" {
			key = "clients"
		}
		mux.HandleFunc(path, s.requireAdmin(s.dataEndpoint(key, fixtureName)))
	}
	mux.Handle("/", http.FileServer(http.Dir(s.config.WebDir)))
	return requestLimits(mux)
}

func (s *Server) dataEndpoint(key, fixtureName string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.config.Mode == "fixture" {
			s.serveFixture(w, fixtureName)
			return
		}
		data, meta, err := s.live.get(r.Context(), key)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "live data unavailable")
			return
		}
		writeEnvelope(w, data, meta)
	}
}

func requestLimits(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		if r.TLS != nil {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		}
		isSessionMutation := r.URL.Path == "/api/v1/session" && (r.Method == http.MethodPost || r.Method == http.MethodDelete)
		if r.Method != http.MethodGet && r.Method != http.MethodHead && !isSessionMutation {
			writeError(w, http.StatusMethodNotAllowed, "read-only API")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "mode": s.config.Mode})
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	identity, status := s.authenticate(r)
	if status != http.StatusOK {
		writeError(w, status, http.StatusText(status))
		return
	}
	writeJSON(w, http.StatusOK, identity)
}

func (s *Server) session(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		s.login(w, r)
	case http.MethodDelete:
		s.logout(w, r)
	default:
		writeError(w, http.StatusMethodNotAllowed, "POST or DELETE required")
	}
}

func (s *Server) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		identity, status := s.authenticate(r)
		if status != http.StatusOK {
			writeError(w, status, http.StatusText(status))
			return
		}
		if identity.Role != roleAdmin {
			writeError(w, http.StatusForbidden, "ADMIN role required")
			return
		}
		next(w, r)
	}
}

func (s *Server) authenticate(r *http.Request) (identity, int) {
	if cookie, err := r.Cookie(sessionCookieName); err == nil {
		if authenticated, ok := s.verifySession(cookie.Value); ok {
			return authenticated, http.StatusOK
		}
	}
	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, prefix) {
		return identity{}, http.StatusUnauthorized
	}
	token := strings.TrimPrefix(header, prefix)
	if constantTimeTokenEqual(token, s.config.AdminToken) {
		return identity{Subject: "automation-admin", Role: roleAdmin}, http.StatusOK
	}
	if constantTimeTokenEqual(token, s.config.UserToken) {
		return identity{Subject: "automation-user", Role: roleUser}, http.StatusOK
	}
	return identity{}, http.StatusUnauthorized
}

func (s *Server) disks(w http.ResponseWriter, r *http.Request) {
	const prefix = "/api/v1/admin/nodes/"
	remainder := strings.TrimPrefix(r.URL.Path, prefix)
	parts := strings.Split(strings.Trim(remainder, "/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] != "disks" {
		writeError(w, http.StatusNotFound, "route not found")
		return
	}
	if s.config.Mode == "live" {
		data, meta, err := s.live.get(r.Context(), "disks:"+parts[0])
		if errors.Is(err, errNodeNotFound) {
			writeError(w, http.StatusNotFound, "node not found")
			return
		}
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "live data unavailable")
			return
		}
		writeEnvelope(w, data, meta)
		return
	}

	data, err := os.ReadFile(filepath.Join(s.config.FixturesDir, "disks.json"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "fixture unavailable")
		return
	}
	var byNode map[string]json.RawMessage
	if err := json.Unmarshal(data, &byNode); err != nil {
		writeError(w, http.StatusInternalServerError, "invalid fixture")
		return
	}
	disks, ok := byNode[parts[0]]
	if !ok {
		writeError(w, http.StatusNotFound, "node not found")
		return
	}
	s.writeFixtureEnvelope(w, disks)
}

func (s *Server) timeseries(w http.ResponseWriter, r *http.Request) {
	metric := r.URL.Query().Get("metric")
	if _, ok := allowedTimeseries[metric]; !ok {
		writeError(w, http.StatusBadRequest, "metric is not whitelisted")
		return
	}
	from, fromErr := time.Parse(time.RFC3339, r.URL.Query().Get("from"))
	to, toErr := time.Parse(time.RFC3339, r.URL.Query().Get("to"))
	if fromErr != nil || toErr != nil || !from.Before(to) || to.Sub(from) > 31*24*time.Hour {
		writeError(w, http.StatusBadRequest, "invalid time range")
		return
	}
	step := 15
	if raw := r.URL.Query().Get("step"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 5 || parsed > 3600 {
			writeError(w, http.StatusBadRequest, "step must be between 5 and 3600 seconds")
			return
		}
		step = parsed
	}
	if s.config.Mode == "live" {
		value, observedAt, err := s.live.fetchTimeseries(r.Context(), metric, from, to, step)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "live data unavailable")
			return
		}
		data, err := json.Marshal(value)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "response encoding failed")
			return
		}
		writeEnvelope(w, data, liveSampleMeta(s.config.Now().UTC(), observedAt, 35*time.Second, ""))
		return
	}

	data, err := os.ReadFile(filepath.Join(s.config.FixturesDir, "timeseries.json"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "fixture unavailable")
		return
	}
	var series map[string]json.RawMessage
	if err := json.Unmarshal(data, &series); err != nil {
		writeError(w, http.StatusInternalServerError, "invalid fixture")
		return
	}
	points, ok := series[metric]
	if !ok {
		points = json.RawMessage("[]")
	}
	payload, err := json.Marshal(map[string]any{
		"metric": metric,
		"from":   from.Format(time.RFC3339),
		"to":     to.Format(time.RFC3339),
		"step":   step,
		"points": points,
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "response encoding failed")
		return
	}
	s.writeFixtureEnvelope(w, payload)
}

func (s *Server) serveFixture(w http.ResponseWriter, fixtureName string) {
	data, err := os.ReadFile(filepath.Join(s.config.FixturesDir, fixtureName))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "fixture unavailable")
		return
	}
	if !json.Valid(data) {
		writeError(w, http.StatusInternalServerError, "invalid fixture")
		return
	}
	s.writeFixtureEnvelope(w, data)
}

func (s *Server) writeFixtureEnvelope(w http.ResponseWriter, data json.RawMessage) {
	now := s.config.Now().UTC()
	writeEnvelope(w, data, sampleMeta{
		Source:      "fixture",
		CollectedAt: now.Format(time.RFC3339),
		AgeSeconds:  0,
		Freshness:   "fresh",
	})
}

func writeEnvelope(w http.ResponseWriter, data json.RawMessage, meta sampleMeta) {
	writeJSON(w, http.StatusOK, envelope{Data: data, Sample: meta})
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{
		"error":  http.StatusText(status),
		"detail": message,
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, "encode response:", err)
	}
}
