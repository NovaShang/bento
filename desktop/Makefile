# Bento desktop (daemon + CLI). Targets here are intentionally tiny; CI just
# calls `make ci`.

GOOS ?=
GOARCH ?=
LDFLAGS = -s -w

.PHONY: build daemon cli test vet clean ci bundled-tmux

build: bundled-tmux daemon cli

daemon:
	go build -ldflags='$(LDFLAGS)' -o bin/bento-daemon ./cmd/bento-daemon

cli:
	go build -ldflags='$(LDFLAGS)' -o bin/bento ./cmd/bento

# bundled-tmux pulls the prebuilt tmux binary for the host OS/arch from the
# GH release pinned in scripts/bundled-tmux.version. Missing release or no
# gh CLI is non-fatal — the runtime resolver falls back to system tmux.
# Run `scripts/build-bundled-tmux.sh` directly to compile from source.
bundled-tmux:
	@../scripts/fetch-bundled-tmux.sh

test:
	go test ./...

vet:
	go vet ./...

clean:
	rm -rf bin

ci: vet test build
