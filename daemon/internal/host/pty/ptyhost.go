// Package ptyhost runs one process under a real pty on behalf of the daemon —
// the engine behind acphost's pty panes (docs/hybrid-workbench-design.md §3):
// the terminal pane sits on it. It is deliberately tiny: a pty pane has no
// control protocol to parse — bytes
// in, bytes out, exit code — so this package owns exactly the process, the
// read pump, and the resize/kill edges, and nothing else.
//
// Dependency direction: acphost → ptyhost; nothing
// here may import acphost.
package ptyhost

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// Default geometry when the spawn names none. Clients send their real size
// in practice; 80×24 is just the least-surprising tty fallback.
const (
	defaultCols = 80
	defaultRows = 24
)

// Options configures one Start.
type Options struct {
	// Cmd is the program to run. "" = the user's login shell: $SHELL from
	// Env (falling back to /bin/zsh, then /bin/sh), invoked with -l so it
	// reads the profile a terminal user expects; Args are appended after
	// the -l. A bare name resolves against Env's PATH; a path containing
	// '/' runs as-is.
	Cmd  string
	Args []string
	// Cwd is the working directory; "" = the daemon's own.
	Cwd string
	// Env is the FULL environment (the caller merges the daemon's env with
	// any overrides — acphost.augmentedEnv's job). TERM is defaulted to
	// xterm-256color when absent: a launchd daemon carries no TERM, and a
	// TERM-less shell breaks every TUI it runs.
	Env []string
	// Cols/Rows is the initial pty size; values ≤ 0 fall back to 80×24.
	Cols, Rows int

	// OnOutput receives the pty's output in read order, from the pump
	// goroutine. It MAY block: the pump then stops reading, the kernel pty
	// buffer fills, and the foreground process blocks on write — the same
	// natural backpressure acphost's credit window exerts on an ACP agent
	// through its stdout pipe. Every call gets its own copy of the bytes.
	OnOutput func([]byte)
	// OnExit fires exactly once, after the final OnOutput: the pump drains
	// the pty to its end before reaping the process, so output is never
	// announced dead and then delivered. Code is the exit code (-1 when a
	// signal ended it) and errMsg is Wait's error text ("" on a clean
	// exit) — the same shape acphost's exit control carries.
	OnExit func(code int, errMsg string)
}

// Proc is one running pty process.
type Proc struct {
	cmd    *exec.Cmd
	ptmx   *os.File
	exited atomic.Bool
}

// Start launches the process on a fresh pty (as session leader, with the
// pty as controlling terminal) and starts the read pump.
func Start(opts Options) (*Proc, error) {
	path, args, err := resolveCommand(opts)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(path, args...)
	cmd.Env = withDefaultTerm(opts.Env)
	if opts.Cwd != "" {
		// Stat first: Go reports a chdir failure as "fork/exec <binary>: no
		// such file or directory", which blames the wrong path — the binary
		// is right there and the DIRECTORY is what's gone (the same trap
		// acphost.spawnInstance documents). Say which.
		if info, err := os.Stat(opts.Cwd); err != nil || !info.IsDir() {
			return nil, fmt.Errorf("working directory not found: %s", opts.Cwd)
		}
		cmd.Dir = opts.Cwd
	}
	cols, rows := opts.Cols, opts.Rows
	if cols <= 0 {
		cols = defaultCols
	}
	if rows <= 0 {
		rows = defaultRows
	}
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)})
	if err != nil {
		return nil, fmt.Errorf("start %s on a pty: %w", path, err)
	}
	p := &Proc{cmd: cmd, ptmx: ptmx}
	go p.pump(opts.OnOutput, opts.OnExit)
	return p, nil
}

// pump is the read loop: pty → OnOutput until the stream ends, then reap and
// report. Wait runs strictly AFTER the last read, so every byte the process
// wrote is delivered before its exit is announced. The stream ends when the
// last fd on the pty's slave side closes — normally the process's own exit;
// for a shell that left background children holding the terminal, when the
// last of those lets go (which is also when the pane truly has nothing more
// to say).
func (p *Proc) pump(onOutput func([]byte), onExit func(int, string)) {
	buf := make([]byte, 32*1024)
	for {
		n, err := p.ptmx.Read(buf)
		if n > 0 && onOutput != nil {
			out := make([]byte, n)
			copy(out, buf[:n])
			onOutput(out)
		}
		if err != nil {
			break // EOF (macOS) or EIO (Linux): the pty is over either way
		}
	}
	werr := p.cmd.Wait()
	p.exited.Store(true)
	_ = p.ptmx.Close()
	code := 0
	if p.cmd.ProcessState != nil {
		code = p.cmd.ProcessState.ExitCode()
	}
	msg := ""
	if werr != nil {
		msg = werr.Error()
	}
	if onExit != nil {
		onExit(code, msg)
	}
}

// Write types bytes into the pty (the terminal's input side). Raw and
// unframed on purpose: terminal input has no line discipline to reassemble
// above the tty's own.
func (p *Proc) Write(b []byte) error {
	_, err := p.ptmx.Write(b)
	return err
}

// Resize sets the pty's size; the kernel delivers SIGWINCH to the foreground
// process group, so a full-screen TUI repaints itself for the new geometry —
// the P2 half of the attach-fidelity plan (docs/hybrid-workbench-design.md
// §5). The ioctl is synchronous: when Resize returns, `stty size` inside the
// pane already reports the new geometry.
func (p *Proc) Resize(cols, rows int) error {
	if cols <= 0 || rows <= 0 {
		return fmt.Errorf("resize wants positive cols and rows, got %dx%d", cols, rows)
	}
	return pty.Setsize(p.ptmx, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)})
}

// Kill ends the process group: SIGHUP first — the "your terminal went away"
// signal, and the one interactive shells actually honor (they IGNORE
// SIGTERM, so the ACP instances' TERM-then-KILL choice would leave every
// plain shell pane immortal) — with a SIGKILL backstop for anything that
// lingers.
func (p *Proc) Kill() {
	proc := p.cmd.Process
	if proc == nil {
		return
	}
	// pty.Start's Setsid makes the child a session leader: pid == pgid.
	pid := proc.Pid
	_ = syscall.Kill(-pid, syscall.SIGHUP)
	go func() {
		time.Sleep(3 * time.Second)
		if p.exited.Load() {
			return // already reaped — the pid may belong to someone else now
		}
		_ = syscall.Kill(-pid, syscall.SIGKILL)
	}()
}

// resolveCommand turns Options into an exec-able path + argv (see
// Options.Cmd for the policy).
func resolveCommand(opts Options) (string, []string, error) {
	if opts.Cmd != "" {
		if strings.Contains(opts.Cmd, "/") {
			return opts.Cmd, opts.Args, nil
		}
		path, err := lookPathIn(envValue(opts.Env, "PATH"), opts.Cmd)
		if err != nil {
			return "", nil, err
		}
		return path, opts.Args, nil
	}
	for _, cand := range []string{envValue(opts.Env, "SHELL"), "/bin/zsh", "/bin/sh"} {
		if cand != "" && isExecutable(cand) {
			return cand, append([]string{"-l"}, opts.Args...), nil
		}
	}
	return "", nil, errors.New("no login shell found ($SHELL unset; /bin/zsh and /bin/sh missing)")
}

// envValue reads a key from an execve-style env slice; last one wins, like
// execve itself.
func envValue(env []string, key string) string {
	prefix := key + "="
	val := ""
	for _, kv := range env {
		if strings.HasPrefix(kv, prefix) {
			val = strings.TrimPrefix(kv, prefix)
		}
	}
	return val
}

func lookPathIn(pathVar, cmd string) (string, error) {
	for _, dir := range strings.Split(pathVar, ":") {
		if dir == "" {
			continue
		}
		cand := filepath.Join(dir, cmd)
		if isExecutable(cand) {
			return cand, nil
		}
	}
	return "", fmt.Errorf("%s not found in PATH", cmd)
}

func isExecutable(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir() && info.Mode().Perm()&0o111 != 0
}

// withDefaultTerm appends TERM=xterm-256color when the env has no TERM.
func withDefaultTerm(env []string) []string {
	if envValue(env, "TERM") != "" {
		return env
	}
	return append(append([]string(nil), env...), "TERM=xterm-256color")
}
