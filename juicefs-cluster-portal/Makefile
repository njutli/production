.PHONY: test run fmt

GOCACHE ?= /tmp/juicefs-cluster-portal-go-cache
export GOCACHE

test:
	cd api && go test ./...

run:
	cd api && go run ./cmd/portal

fmt:
	cd api && gofmt -w $$(find . -name '*.go' -type f)
