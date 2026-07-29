# Bento desktop (daemon + CLI). Targets here are intentionally tiny; CI just
# calls `make ci`.

GOOS ?=
GOARCH ?=
LDFLAGS = -s -w

.PHONY: build daemon cli test vet clean ci

build: daemon cli

daemon:
	go build -ldflags='$(LDFLAGS)' -o bin/bento-daemon ./cmd/bento-daemon

cli:
	go build -ldflags='$(LDFLAGS)' -o bin/bento ./cmd/bento

test:
	go test ./...

vet:
	go vet ./...

clean:
	rm -rf bin

ci: vet test build
