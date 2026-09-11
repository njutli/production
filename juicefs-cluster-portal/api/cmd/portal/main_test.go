package main

import "testing"

func TestIsLoopback(t *testing.T) {
	for _, addr := range []string{"127.0.0.1:8080", "[::1]:8080", "localhost:8080"} {
		if !isLoopback(addr) {
			t.Errorf("expected loopback: %s", addr)
		}
	}
	for _, addr := range []string{"0.0.0.0:8080", "10.20.1.152:8080", "bad-address"} {
		if isLoopback(addr) {
			t.Errorf("expected non-loopback: %s", addr)
		}
	}
}
