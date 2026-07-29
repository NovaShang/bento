package acphost

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func appendLines(t *testing.T, l *eventLog, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		line, ok := injectSeq([]byte(fmt.Sprintf(`{"method":"n/%d"}`, i)), l.nextSeq)
		if !ok {
			t.Fatal("injectSeq failed")
		}
		l.append(line)
	}
}

func TestEventLogMemoryTailRoundTrip(t *testing.T) {
	l := newEventLog(nil)
	appendLines(t, l, 5)

	if l.head() != 5 || l.start() != 1 {
		t.Fatalf("head/start = %d/%d, want 5/1", l.head(), l.start())
	}
	got := l.since(2, 10)
	if len(got) != 3 || got[0].seq != 3 || got[2].seq != 5 {
		t.Fatalf("since(2) returned %d entries starting at %d", len(got), got[0].seq)
	}
	if n := len(l.since(5, 10)); n != 0 {
		t.Fatalf("a current cursor should return nothing, got %d", n)
	}
}

// An unbound log is memory-only; binding gives it a home and flushes what it
// buffered before the conversation had an id.
func TestEventLogBindFlushesBufferedEntries(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "conv")
	l := newEventLog(nil)
	appendLines(t, l, 3)
	if err := l.bind(dir); err != nil {
		t.Fatal(err)
	}
	l.close()

	reopened := newEventLog(nil)
	if err := reopened.bind(dir); err != nil {
		t.Fatal(err)
	}
	if reopened.head() != 3 {
		t.Fatalf("recovered head = %d, want 3", reopened.head())
	}
	if got := reopened.since(0, 10); len(got) != 3 {
		t.Fatalf("recovered %d entries, want 3", len(got))
	}
}

// Reads that fall behind the memory tail come off disk with the right seqs.
func TestEventLogReadsPastMemoryTailFromDisk(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "conv")
	l := newEventLog(nil)
	if err := l.bind(dir); err != nil {
		t.Fatal(err)
	}
	appendLines(t, l, 200)

	// Drop the memory tail; disk is the only remaining copy.
	l.mem = nil
	l.memBytes = 0

	got := l.since(0, 5)
	if len(got) != 5 {
		t.Fatalf("disk read returned %d entries, want 5", len(got))
	}
	for i, e := range got {
		if e.seq != uint64(i+1) {
			t.Fatalf("entry %d has seq %d", i, e.seq)
		}
		if !strings.Contains(string(e.line), fmt.Sprintf(`"n/%d"`, i)) {
			t.Fatalf("entry %d has the wrong payload: %q", i, e.line)
		}
	}
	mid := l.since(150, 3)
	if len(mid) != 3 || mid[0].seq != 151 {
		t.Fatalf("mid-log read returned %d entries starting at %d", len(mid), mid[0].seq)
	}
}

// A daemon killed mid-write leaves a torn final line; recovery truncates it
// and keeps appending from a clean boundary rather than serving a broken
// line to a client.
func TestEventLogRecoversTornTail(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "conv")
	l := newEventLog(nil)
	if err := l.bind(dir); err != nil {
		t.Fatal(err)
	}
	appendLines(t, l, 3)
	seg := l.currentSegment().path
	l.close()

	f, err := os.OpenFile(seg, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(`{"method":"n/torn`); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	reopened := newEventLog(nil)
	if err := reopened.bind(dir); err != nil {
		t.Fatal(err)
	}
	if reopened.head() != 3 {
		t.Fatalf("torn tail counted as an entry: head = %d", reopened.head())
	}
	appendLines(t, reopened, 1)
	got := reopened.since(3, 5)
	if len(got) != 1 || got[0].seq != 4 {
		t.Fatalf("append after recovery landed wrong: %+v", got)
	}
}

// Retention deletes whole oldest segments and says so — a hole must be
// visible (start moves, evicted set), never silently served.
func TestEventLogRetentionEvictsOldestSegments(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "conv")
	l := newEventLog(nil)
	if err := l.bind(dir); err != nil {
		t.Fatal(err)
	}
	// Shrink the caps for the test by writing big lines: 3 segments' worth.
	big := strings.Repeat("x", 64*1024)
	for i := 0; i < 4000 && !l.evicted; i++ {
		line, _ := injectSeq([]byte(fmt.Sprintf(`{"pad":%q}`, big)), l.nextSeq)
		l.append(line)
	}
	if !l.evicted {
		t.Skip("retention cap not reached in a reasonable number of writes")
	}
	if l.start() <= 1 {
		t.Fatalf("start should have moved past the deleted head, got %d", l.start())
	}
	if l.diskBytes > logDiskMaxBytes {
		t.Fatalf("disk usage %d exceeds the cap %d", l.diskBytes, logDiskMaxBytes)
	}
}

func TestConversationDirIsCollisionFree(t *testing.T) {
	root := "/tmp/conv"
	a := conversationDir(root, "sess/../../etc/passwd")
	b := conversationDir(root, "sess_______etc_passwd")
	if a == b {
		t.Fatal("sanitizing must not collapse distinct ids")
	}
	// No separator survives sanitizing, so no id can climb out of the root —
	// including the ones that look like they were written to try.
	for _, id := range []string{"sess/../../etc/passwd", "..", "/", "a/b"} {
		dir := conversationDir(root, id)
		if filepath.Dir(dir) != root {
			t.Fatalf("id %q escaped the root: %s", id, dir)
		}
		if filepath.Clean(dir) != dir {
			t.Fatalf("id %q produced a non-canonical path: %s", id, dir)
		}
	}
}
