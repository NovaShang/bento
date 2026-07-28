package acphost

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// eventLog is one conversation's sequenced scrollback.
//
// It is a HYBRID: a bounded in-memory tail serves the hot path (live
// broadcast and the usual "catch up the last few hundred updates" attach)
// with no I/O at all, while every entry is also appended to a durable,
// segmented on-disk history under the conversation's own directory. The
// disk copy is what makes a daemon restart keep the transcript, and what
// lets a phone that has been away for a day catch up without asking the
// agent to re-replay its whole conversation.
//
// Layout, one directory per conversation:
//
//	<root>/<conversation-id>/seg-<firstSeq>.jsonl
//
// Entries are the final wire bytes ('{"_seq":N,…}\n'), so both replay paths
// are a straight sendStdio. Seqs are contiguous and start at 1 — 0 means
// "no cursor" on the wire, so it must never be a real entry's stamp.
//
// The log is created UNBOUND (memory only) because a freshly spawned agent
// has no conversation id yet; `bind` attaches it to a directory as soon as
// the id is known (spawn carries it when resuming, otherwise session/new or
// session/load reveals it) and flushes whatever was buffered.
//
// All methods are called with inst.mu held. Reads that miss the memory tail
// touch the disk under that lock: they are bounded (one batch, ≤ 64 lines,
// from the page cache) and only happen on a cold attach.
type eventLog struct {
	dir     string // "" = unbound (memory only)
	nextSeq uint64
	evicted bool // disk retention dropped the oldest entries

	// In-memory tail (always populated, bound or not).
	mem      []logEntry
	memBytes int

	// Durable history.
	segs      []*logSegment
	cur       *os.File
	diskBytes int64
	log       func(msg string, args ...any)
}

// logSegment is one on-disk file. `offsets[i]` is the byte offset of the
// entry with seq firstSeq+i, so a seek is index math rather than a scan.
type logSegment struct {
	firstSeq uint64
	path     string
	offsets  []int64
	bytes    int64
}

type logEntry struct {
	seq  uint64
	line []byte
}

const (
	// memTailMaxBytes bounds the in-memory tail. Overflow drops the oldest
	// entries from MEMORY only — they stay on disk, so a catch-up that
	// reaches past the tail reads instead of degrading.
	memTailMaxBytes = 16 << 20

	// logSegmentBytes is the size at which a new segment file starts.
	logSegmentBytes = 8 << 20

	// logDiskMaxBytes caps one conversation's durable history. Overflow
	// deletes whole oldest segments and marks the log incomplete — catch-up
	// then degrades to the session/load path instead of serving a hole.
	logDiskMaxBytes = 128 << 20
)

func newEventLog(logf func(string, ...any)) *eventLog {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &eventLog{nextSeq: 1, log: logf}
}

// conversationDir is the on-disk home for one conversation id. Agent session
// ids are opaque strings, so the name is sanitized and suffixed with a hash
// of the original — readable in a file listing, still collision-free.
func conversationDir(root, conversationID string) string {
	var b strings.Builder
	for _, r := range conversationID {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '.', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	name := b.String()
	if len(name) > 48 {
		name = name[:48]
	}
	sum := sha256.Sum256([]byte(conversationID))
	return filepath.Join(root, name+"-"+hex.EncodeToString(sum[:4]))
}

// bind attaches the log to a conversation directory, recovering whatever is
// already there (daemon restart, or a second process for the same
// conversation). Idempotent for the same directory.
//
// Ordering note: bind runs before any notification for the conversation can
// be logged — at spawn when the client names the conversation, otherwise on
// the session/load request or the session/new response. So exactly one of
// "recovered history" / "buffered entries" is non-empty in practice. If both
// somehow are, the durable history wins and the buffered entries stay
// memory-only: seqs continue past the recovered head, so no client ever sees
// a stamp move backwards.
func (l *eventLog) bind(dir string) error {
	if l.dir == dir {
		return nil
	}
	if l.dir != "" {
		return fmt.Errorf("event log already bound to %s", l.dir)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	segs, err := recoverSegments(dir)
	if err != nil {
		return err
	}
	l.dir = dir
	l.segs = segs
	for _, s := range segs {
		l.diskBytes += s.bytes
	}

	if len(segs) > 0 {
		last := segs[len(segs)-1]
		recoveredNext := last.firstSeq + uint64(len(last.offsets))
		if len(l.mem) > 0 {
			l.log("acp event log: buffered entries kept memory-only (recovered history wins)",
				"dir", dir, "buffered", len(l.mem))
		}
		if recoveredNext > l.nextSeq {
			l.nextSeq = recoveredNext
		}
		// Continue in a fresh segment: appending into the recovered tail
		// file would need its offsets re-derived on every restart.
		return nil
	}

	// Fresh directory: persist whatever was buffered before the id was known.
	for _, e := range l.mem {
		if err := l.writeDisk(e); err != nil {
			return err
		}
	}
	return nil
}

// recoverSegments rebuilds the offset index for an existing directory and
// truncates a torn final line (the daemon died mid-write).
func recoverSegments(dir string) ([]*logSegment, error) {
	names, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var segs []*logSegment
	for _, e := range names {
		if e.IsDir() || !strings.HasPrefix(e.Name(), "seg-") || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		raw := strings.TrimSuffix(strings.TrimPrefix(e.Name(), "seg-"), ".jsonl")
		first, err := strconv.ParseUint(raw, 10, 64)
		if err != nil {
			continue
		}
		seg, err := indexSegment(filepath.Join(dir, e.Name()), first)
		if err != nil {
			return nil, err
		}
		if len(seg.offsets) == 0 {
			_ = os.Remove(seg.path)
			continue
		}
		segs = append(segs, seg)
	}
	sort.Slice(segs, func(i, j int) bool { return segs[i].firstSeq < segs[j].firstSeq })

	// A gap means an older segment was deleted by retention (fine) but a
	// segment whose seqs overlap its successor would break index math; drop
	// anything that isn't a clean ascending chain.
	var chain []*logSegment
	for _, s := range segs {
		if n := len(chain); n > 0 {
			prev := chain[n-1]
			if s.firstSeq < prev.firstSeq+uint64(len(prev.offsets)) {
				continue
			}
		}
		chain = append(chain, s)
	}
	return chain, nil
}

func indexSegment(path string, firstSeq uint64) (*logSegment, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	seg := &logSegment{firstSeq: firstSeq, path: path}
	r := bufio.NewReaderSize(f, 128*1024)
	var off int64
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 && line[len(line)-1] == '\n' {
			seg.offsets = append(seg.offsets, off)
			off += int64(len(line))
		} else if len(line) > 0 {
			// Torn tail: drop it so appends resume from a clean boundary.
			if truncErr := os.Truncate(path, off); truncErr != nil {
				return nil, truncErr
			}
		}
		if err != nil {
			if err == io.EOF {
				break
			}
			return nil, err
		}
	}
	seg.bytes = off
	return seg, nil
}

func (l *eventLog) head() uint64 { return l.nextSeq - 1 }

// start is the oldest retained seq (head+1 when empty — makes the gapless
// check `have+1 >= start` degrade correctly).
func (l *eventLog) start() uint64 {
	if len(l.segs) > 0 {
		return l.segs[0].firstSeq
	}
	if len(l.mem) > 0 {
		return l.mem[0].seq
	}
	return l.nextSeq
}

func (l *eventLog) append(line []byte) uint64 {
	seq := l.nextSeq
	l.nextSeq++
	entry := logEntry{seq: seq, line: line}

	if l.dir != "" {
		if err := l.writeDisk(entry); err != nil {
			// A failed write must not stop the conversation: the memory tail
			// still serves live viewers and near-term catch-up.
			l.log("acp event log: append failed", "dir", l.dir, "err", err)
		}
	}

	l.mem = append(l.mem, entry)
	l.memBytes += len(line)
	for l.memBytes > memTailMaxBytes && len(l.mem) > 1 {
		l.memBytes -= len(l.mem[0].line)
		l.mem[0].line = nil
		l.mem = l.mem[1:]
	}
	// Reslicing keeps the backing array alive; compact once it's mostly gaps.
	if cap(l.mem) > 64 && len(l.mem) < cap(l.mem)/2 {
		l.mem = append([]logEntry(nil), l.mem...)
	}
	return seq
}

func (l *eventLog) writeDisk(e logEntry) error {
	if l.cur == nil || l.currentSegment().bytes >= logSegmentBytes {
		if err := l.rotate(e.seq); err != nil {
			return err
		}
	}
	seg := l.currentSegment()
	n, err := l.cur.Write(e.line)
	if err != nil {
		return err
	}
	seg.offsets = append(seg.offsets, seg.bytes)
	seg.bytes += int64(n)
	l.diskBytes += int64(n)
	l.enforceDiskCap()
	return nil
}

func (l *eventLog) currentSegment() *logSegment {
	if len(l.segs) == 0 {
		return nil
	}
	return l.segs[len(l.segs)-1]
}

func (l *eventLog) rotate(firstSeq uint64) error {
	if l.cur != nil {
		_ = l.cur.Close()
		l.cur = nil
	}
	path := filepath.Join(l.dir, fmt.Sprintf("seg-%d.jsonl", firstSeq))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	l.cur = f
	l.segs = append(l.segs, &logSegment{firstSeq: firstSeq, path: path})
	return nil
}

// enforceDiskCap deletes whole oldest segments past the cap. The current
// segment is never deleted.
func (l *eventLog) enforceDiskCap() {
	for l.diskBytes > logDiskMaxBytes && len(l.segs) > 1 {
		victim := l.segs[0]
		if err := os.Remove(victim.path); err != nil && !os.IsNotExist(err) {
			l.log("acp event log: retention delete failed", "path", victim.path, "err", err)
			return
		}
		l.diskBytes -= victim.bytes
		l.segs = l.segs[1:]
		l.evicted = true
	}
}

// since returns up to max entries with seq > cursor, from the memory tail
// when it covers them and from disk otherwise.
func (l *eventLog) since(cursor uint64, max int) []logEntry {
	want := cursor + 1
	if want >= l.nextSeq || max <= 0 {
		return nil
	}
	if len(l.mem) > 0 && want >= l.mem[0].seq {
		idx := int(want - l.mem[0].seq)
		if idx >= len(l.mem) {
			return nil
		}
		end := idx + max
		if end > len(l.mem) {
			end = len(l.mem)
		}
		return append([]logEntry(nil), l.mem[idx:end]...)
	}
	return l.readDisk(want, max)
}

func (l *eventLog) readDisk(want uint64, max int) []logEntry {
	seg, idx := l.locate(want)
	if seg == nil {
		return nil
	}
	f, err := os.Open(seg.path)
	if err != nil {
		l.log("acp event log: read failed", "path", seg.path, "err", err)
		return nil
	}
	defer f.Close()
	if _, err := f.Seek(seg.offsets[idx], io.SeekStart); err != nil {
		return nil
	}
	out := make([]logEntry, 0, max)
	seq := seg.firstSeq + uint64(idx)
	r := bufio.NewReaderSize(f, 128*1024)
	for len(out) < max {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 && line[len(line)-1] == '\n' {
			out = append(out, logEntry{seq: seq, line: line})
			seq++
		}
		if err != nil {
			break
		}
	}
	return out
}

// locate finds the segment holding `seq` and its index within it. A seq that
// falls in a retention gap resolves to the oldest retained entry, so a
// catch-up past the cap returns what still exists (the caller compares
// against `start` to notice the hole).
func (l *eventLog) locate(seq uint64) (*logSegment, int) {
	for i := len(l.segs) - 1; i >= 0; i-- {
		s := l.segs[i]
		if len(s.offsets) == 0 {
			continue
		}
		if seq >= s.firstSeq {
			idx := int(seq - s.firstSeq)
			if idx >= len(s.offsets) {
				return nil, 0
			}
			return s, idx
		}
	}
	if len(l.segs) > 0 && len(l.segs[0].offsets) > 0 {
		return l.segs[0], 0
	}
	return nil, 0
}

func (l *eventLog) close() {
	if l.cur != nil {
		_ = l.cur.Close()
		l.cur = nil
	}
}

// injectSeq stamps `_seq` into a notification's top-level envelope. Go maps
// marshal with sorted keys, so the stamp lands FIRST ('_' < any letter) —
// clients rely on the `{"_seq":` prefix for cheap extraction.
func injectSeq(raw []byte, seq uint64) ([]byte, bool) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, false
	}
	obj["_seq"] = json.RawMessage(strconv.FormatUint(seq, 10))
	out, err := json.Marshal(obj)
	if err != nil {
		return nil, false
	}
	return append(out, '\n'), true
}
