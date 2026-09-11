package main

import (
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"juicefs-cluster-portal/api/internal/portal"
)

func main() {
	mode := envOr("PORTAL_MODE", "fixture")
	addr := envOr("PORTAL_ADDR", "127.0.0.1:8080")
	tlsAddr := os.Getenv("PORTAL_TLS_ADDR")
	if mode == "fixture" && !isLoopback(addr) {
		log.Fatal("fixture mode may only listen on loopback")
	}
	if mode == "fixture" && tlsAddr != "" && !isLoopback(tlsAddr) {
		log.Fatal("fixture mode TLS may only listen on loopback")
	}
	secureCookies, err := strconv.ParseBool(envOr("PORTAL_SECURE_COOKIES", "false"))
	if err != nil {
		log.Fatal("invalid PORTAL_SECURE_COOKIES")
	}
	sessionTTL, err := time.ParseDuration(envOr("PORTAL_SESSION_TTL", "8h"))
	if err != nil {
		log.Fatal("invalid PORTAL_SESSION_TTL")
	}
	config := portal.Config{
		Mode:              mode,
		FixturesDir:       envOr("PORTAL_FIXTURES_DIR", "../fixtures"),
		WebDir:            envOr("PORTAL_WEB_DIR", "../web"),
		AdminToken:        envOr("PORTAL_ADMIN_TOKEN", "fixture-admin-token"),
		UserToken:         envOr("PORTAL_USER_TOKEN", "fixture-user-token"),
		UsersFile:         os.Getenv("PORTAL_USERS_FILE"),
		SessionSecretFile: os.Getenv("PORTAL_SESSION_SECRET_FILE"),
		SessionTTL:        sessionTTL,
		SecureCookies:     secureCookies,
		PrometheusURL:     envOr("PORTAL_PROMETHEUS_URL", "http://127.0.0.1:9090"),
		NamespaceDBPath:   os.Getenv("PORTAL_NAMESPACE_DB"),
	}
	if mode == "fixture" && config.UsersFile == "" {
		adminHash, hashErr := portal.HashPassword("fixture-admin-password")
		if hashErr != nil {
			log.Fatal(hashErr)
		}
		userHash, hashErr := portal.HashPassword("fixture-user-password")
		if hashErr != nil {
			log.Fatal(hashErr)
		}
		config.LocalUsers = []portal.LocalUser{
			{Username: "admin", Role: "ADMIN", PasswordHash: adminHash},
			{Username: "user", Role: "USER", PasswordHash: userHash, NamespaceRoots: []string{"team-a"}},
		}
		config.SessionSecret = []byte("fixture-session-secret-not-for-live-use")
	}
	server, err := portal.New(config)
	if err != nil {
		log.Fatal(err)
	}
	handler := server.Handler()
	httpServer := newHTTPServer(addr, handler)
	errorsChannel := make(chan error, 2)
	go func() {
		log.Printf("%s portal listening on http://%s", mode, addr)
		errorsChannel <- httpServer.ListenAndServe()
	}()
	if tlsAddr != "" {
		certFile := os.Getenv("PORTAL_TLS_CERT_FILE")
		keyFile := os.Getenv("PORTAL_TLS_KEY_FILE")
		if certFile == "" || keyFile == "" || !secureCookies {
			log.Fatal("TLS listener requires certificate, key and secure cookies")
		}
		tlsServer := newHTTPServer(tlsAddr, handler)
		go func() {
			log.Printf("%s portal listening on https://%s", mode, tlsAddr)
			errorsChannel <- tlsServer.ListenAndServeTLS(certFile, keyFile)
		}()
	}
	if err := <-errorsChannel; !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func newHTTPServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
}

func isLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
