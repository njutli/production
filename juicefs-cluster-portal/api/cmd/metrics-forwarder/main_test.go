package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func testClient(body string) *http.Client {
	return &http.Client{
		Timeout: time.Second,
		Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     make(http.Header),
				Body:       io.NopCloser(strings.NewReader(body)),
			}, nil
		}),
	}
}

func TestValidListenRequiresLiteralIP(t *testing.T) {
	if !validListen("10.20.1.157:9633") || validListen("localhost:9633") || validListen(":9633") {
		t.Fatal("listen validation contract failed")
	}
}

func TestValidUpstreamRequiresLoopbackMetrics(t *testing.T) {
	if !validUpstream("http://127.0.0.1:9567/metrics") || !validUpstream("http://localhost:9567/metrics") {
		t.Fatal("expected loopback metrics URLs to pass")
	}
	for _, raw := range []string{
		"https://127.0.0.1:9567/metrics",
		"http://10.20.1.157:9567/metrics",
		"http://127.0.0.1:9567/admin",
		"http://127.0.0.1:9567/metrics?x=1",
	} {
		if validUpstream(raw) {
			t.Fatalf("unexpected valid upstream: %s", raw)
		}
	}
}

func TestMetricsProxyIsReadOnlyAndBounded(t *testing.T) {
	client := testClient("metric_total 1\n")

	for _, method := range []string{http.MethodGet, http.MethodHead} {
		recorder := httptest.NewRecorder()
		serveMetrics(client, "http://127.0.0.1:9567/metrics", recorder, newRequest(method))
		if recorder.Code != http.StatusOK {
			t.Fatalf("method=%s status=%d", method, recorder.Code)
		}
	}
	recorder := httptest.NewRecorder()
	request, _ := http.NewRequest(http.MethodPost, "http://forwarder/metrics", strings.NewReader("x"))
	serveMetrics(client, "http://127.0.0.1:9567/metrics", recorder, request)
	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf("write status=%d", recorder.Code)
	}
}

func TestMetricsProxyRejectsOversizedBody(t *testing.T) {
	recorder := httptest.NewRecorder()
	serveMetrics(testClient(strings.Repeat("x", maxMetricsBytes+1)), "http://127.0.0.1:9567/metrics", recorder, newRequest(http.MethodGet))
	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("status=%d", recorder.Code)
	}
}

func newRequest(method string) *http.Request {
	request, _ := http.NewRequest(method, "http://forwarder/metrics", nil)
	return request
}
