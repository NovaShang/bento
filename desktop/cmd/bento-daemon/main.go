// bento-daemon is the long-running process on Mac/Linux hosts. It maintains
// a WSS tunnel to the Cloudflare relay and runs an embedded SSH server that
// paired iOS devices reach through that tunnel.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/novashang/bento/desktop/internal/ipc"
)

const version = "0.0.1-dev"

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
	c, err := ipc.NewClient()
	if err != nil {
		return err
	}
	st, err := c.Status(context.Background())
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(st)
}
