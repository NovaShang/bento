// bento-daemon is the long-running process on Mac/Linux hosts. It maintains
// a WSS tunnel to the Cloudflare relay and runs an embedded SSH server that
// paired iOS devices reach through that tunnel.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/novashang/bento/desktop/internal/ipc"
)

// version is overridden at link time by the release workflow via
// `-ldflags='-X main.version=<tag>'`. Dev builds keep the placeholder.
var version = "0.0.1-dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "start":
		fs := flag.NewFlagSet("start", flag.ExitOnError)
		relay := fs.String("relay", "", "relay base URL (overrides config)")
		_ = fs.Parse(os.Args[2:])
		if err := runDaemon(context.Background(), *relay); err != nil {
			die(err)
		}
	case "status":
		if err := runStatus(); err != nil {
			die(err)
		}
	case "version", "--version", "-v":
		fmt.Println("bento-daemon", version)
	case "help", "--help", "-h":
		usage()
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `bento-daemon — Bento background process

Usage:
  bento-daemon start [--relay URL]   Run in the foreground
  bento-daemon status                Print runtime state (talks to running daemon)
  bento-daemon version`)
}

func die(err error) {
	fmt.Fprintln(os.Stderr, "bento-daemon:", err)
	os.Exit(1)
}

// runStatus dials the running daemon's IPC socket and prints its status.
func runStatus() error {
	return ipc.PrintStatus(context.Background(), os.Stdout, false)
}
