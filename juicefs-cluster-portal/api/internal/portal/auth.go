package portal

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/argon2"
)

const (
	sessionCookieName = "jfsportal_session"
	defaultSessionTTL = 8 * time.Hour
	maxLoginBodyBytes = 4096
)

var usernamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

type LocalUser struct {
	Username       string   `json:"username"`
	Role           string   `json:"role"`
	PasswordHash   string   `json:"passwordHash"`
	Disabled       bool     `json:"disabled"`
	NamespaceRoots []string `json:"namespaceRoots,omitempty"`
}

type usersDocument struct {
	Version int         `json:"version"`
	Users   []LocalUser `json:"users"`
}

type identity struct {
	Subject   string `json:"subject"`
	Role      string `json:"role"`
	ExpiresAt string `json:"expiresAt,omitempty"`
}

type sessionClaims struct {
	Version   int    `json:"v"`
	Subject   string `json:"sub"`
	Role      string `json:"role"`
	IssuedAt  int64  `json:"iat"`
	ExpiresAt int64  `json:"exp"`
}

type loginAttempt struct {
	Failures     int
	WindowStart  time.Time
	BlockedUntil time.Time
}

type loginLimiter struct {
	mu       sync.Mutex
	attempts map[string]loginAttempt
}

func newLoginLimiter() *loginLimiter {
	return &loginLimiter{attempts: make(map[string]loginAttempt)}
}

func (l *loginLimiter) allow(key string, now time.Time) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	attempt, ok := l.attempts[key]
	if !ok || (!attempt.BlockedUntil.IsZero() && !now.Before(attempt.BlockedUntil)) {
		if ok {
			delete(l.attempts, key)
		}
		return true, 0
	}
	if now.Before(attempt.BlockedUntil) {
		return false, attempt.BlockedUntil.Sub(now)
	}
	return true, 0
}

func (l *loginLimiter) failure(key string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	attempt := l.attempts[key]
	if attempt.WindowStart.IsZero() || now.Sub(attempt.WindowStart) > 5*time.Minute {
		attempt = loginAttempt{WindowStart: now}
	}
	attempt.Failures++
	if attempt.Failures >= 5 {
		attempt.BlockedUntil = now.Add(5 * time.Minute)
	}
	l.attempts[key] = attempt
}

func (l *loginLimiter) success(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.attempts, key)
}

func loadUsers(path string) (map[string]LocalUser, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read users file: %w", err)
	}
	var document usersDocument
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("decode users file: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return nil, errors.New("users file contains trailing data")
	}
	if document.Version != 1 || len(document.Users) == 0 {
		return nil, errors.New("users file must contain version 1 and at least one user")
	}
	users := make(map[string]LocalUser, len(document.Users))
	for _, user := range document.Users {
		if !usernamePattern.MatchString(user.Username) {
			return nil, fmt.Errorf("invalid username %q", user.Username)
		}
		if user.Role != roleAdmin && user.Role != roleUser {
			return nil, fmt.Errorf("invalid role for %q", user.Username)
		}
		if _, exists := users[user.Username]; exists {
			return nil, fmt.Errorf("duplicate username %q", user.Username)
		}
		seenRoots := make(map[string]struct{}, len(user.NamespaceRoots))
		for _, rootID := range user.NamespaceRoots {
			if !namespaceRootIDPattern.MatchString(rootID) {
				return nil, fmt.Errorf("invalid namespace root for %q", user.Username)
			}
			if _, exists := seenRoots[rootID]; exists {
				return nil, fmt.Errorf("duplicate namespace root for %q", user.Username)
			}
			seenRoots[rootID] = struct{}{}
		}
		if _, err := decodePasswordHash(user.PasswordHash); err != nil {
			return nil, fmt.Errorf("invalid password hash for %q: %w", user.Username, err)
		}
		users[user.Username] = user
	}
	return users, nil
}

func loadSessionSecret(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read session secret: %w", err)
	}
	secret, err := hex.DecodeString(strings.TrimSpace(string(data)))
	if err != nil || len(secret) < 32 {
		return nil, errors.New("session secret must be at least 32 bytes encoded as hex")
	}
	return secret, nil
}

func HashPassword(password string) (string, error) {
	if len(password) < 16 || len(password) > 128 {
		return "", errors.New("password length must be between 16 and 128 bytes")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	const memory = 64 * 1024
	const iterations = 3
	const parallelism = 2
	hash := argon2.IDKey([]byte(password), salt, iterations, memory, parallelism, 32)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, memory, iterations, parallelism,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(hash)), nil
}

type passwordHash struct {
	memory      uint32
	iterations  uint32
	parallelism uint8
	salt        []byte
	hash        []byte
}

func decodePasswordHash(encoded string) (passwordHash, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" || parts[2] != "v=19" {
		return passwordHash{}, errors.New("unsupported password hash format")
	}
	var memory, iterations uint32
	var parallelism uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &iterations, &parallelism); err != nil {
		return passwordHash{}, errors.New("invalid Argon2 parameters")
	}
	if memory < 19*1024 || memory > 128*1024 || iterations < 2 || iterations > 10 || parallelism < 1 || parallelism > 8 {
		return passwordHash{}, errors.New("Argon2 parameters outside accepted bounds")
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(salt) < 16 || len(salt) > 64 {
		return passwordHash{}, errors.New("invalid Argon2 salt")
	}
	hash, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil || len(hash) < 16 || len(hash) > 64 {
		return passwordHash{}, errors.New("invalid Argon2 output")
	}
	return passwordHash{memory: memory, iterations: iterations, parallelism: parallelism, salt: salt, hash: hash}, nil
}

func verifyPassword(encoded, password string) bool {
	if len(password) > 128 {
		return false
	}
	parameters, err := decodePasswordHash(encoded)
	if err != nil {
		return false
	}
	candidate := argon2.IDKey([]byte(password), parameters.salt, parameters.iterations, parameters.memory, parameters.parallelism, uint32(len(parameters.hash)))
	return subtle.ConstantTimeCompare(candidate, parameters.hash) == 1
}

func (s *Server) signSession(user LocalUser) (string, time.Time, error) {
	now := s.config.Now().UTC()
	expires := now.Add(s.config.SessionTTL)
	claims := sessionClaims{Version: 1, Subject: user.Username, Role: user.Role, IssuedAt: now.Unix(), ExpiresAt: expires.Unix()}
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", time.Time{}, err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, s.sessionSecret)
	_, _ = mac.Write([]byte(encoded))
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return encoded + "." + signature, expires, nil
}

func (s *Server) verifySession(token string) (identity, bool) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return identity{}, false
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return identity{}, false
	}
	mac := hmac.New(sha256.New, s.sessionSecret)
	_, _ = mac.Write([]byte(parts[0]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return identity{}, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return identity{}, false
	}
	var claims sessionClaims
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Version != 1 {
		return identity{}, false
	}
	user, ok := s.users[claims.Subject]
	now := s.config.Now().UTC()
	if !ok || user.Disabled || user.Role != claims.Role || claims.ExpiresAt <= now.Unix() || claims.IssuedAt > now.Add(time.Minute).Unix() {
		return identity{}, false
	}
	return identity{Subject: user.Username, Role: user.Role, ExpiresAt: time.Unix(claims.ExpiresAt, 0).UTC().Format(time.RFC3339)}, true
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	if s.config.SecureCookies && r.TLS == nil {
		writeError(w, http.StatusUpgradeRequired, "HTTPS required for login")
		return
	}
	if contentType := r.Header.Get("Content-Type"); !strings.HasPrefix(contentType, "application/json") {
		writeError(w, http.StatusUnsupportedMediaType, "application/json required")
		return
	}
	key := loginKey(r)
	now := s.config.Now().UTC()
	if allowed, retry := s.loginLimiter.allow(key, now); !allowed {
		retrySeconds := int(retry.Seconds())
		if retrySeconds < 1 {
			retrySeconds = 1
		}
		w.Header().Set("Retry-After", strconv.Itoa(retrySeconds))
		writeError(w, http.StatusTooManyRequests, "login temporarily blocked")
		return
	}
	select {
	case s.loginSlots <- struct{}{}:
		defer func() { <-s.loginSlots }()
	default:
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "login capacity busy")
		return
	}
	body := http.MaxBytesReader(w, r.Body, maxLoginBodyBytes)
	defer body.Close()
	decoder := json.NewDecoder(body)
	decoder.DisallowUnknownFields()
	var request struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := decoder.Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid login request")
		return
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		writeError(w, http.StatusBadRequest, "invalid login request")
		return
	}
	request.Username = strings.TrimSpace(request.Username)
	user, exists := s.users[request.Username]
	hash := s.dummyPasswordHash
	if exists {
		hash = user.PasswordHash
	}
	valid := verifyPassword(hash, request.Password)
	if !exists || user.Disabled || !valid {
		s.loginLimiter.failure(key, now)
		writeError(w, http.StatusUnauthorized, "invalid username or password")
		return
	}
	token, expires, err := s.signSession(user)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "session creation failed")
		return
	}
	s.loginLimiter.success(key)
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookieName, Value: token, Path: "/", Expires: expires,
		MaxAge: int(s.config.SessionTTL.Seconds()), HttpOnly: true, Secure: s.config.SecureCookies,
		SameSite: http.SameSiteStrictMode,
	})
	writeJSON(w, http.StatusOK, identity{Subject: user.Username, Role: user.Role, ExpiresAt: expires.Format(time.RFC3339)})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "DELETE required")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookieName, Value: "", Path: "/", MaxAge: -1, Expires: time.Unix(1, 0),
		HttpOnly: true, Secure: s.config.SecureCookies, SameSite: http.SameSiteStrictMode,
	})
	w.WriteHeader(http.StatusNoContent)
}

func loginKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	return host
}

func constantTimeTokenEqual(left, right string) bool {
	leftSum := sha256.Sum256([]byte(left))
	rightSum := sha256.Sum256([]byte(right))
	return subtle.ConstantTimeCompare(leftSum[:], rightSum[:]) == 1
}
