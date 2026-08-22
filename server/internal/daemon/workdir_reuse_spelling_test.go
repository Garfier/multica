package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Agents such as qoder key their session stores by the raw working-directory
// string they were launched in. Resume must therefore hand the agent the
// spelling the prior task ran with — the one the server recorded in
// task.PriorWorkDir — not a freshly canonicalized one. These tests pin both
// the helper that picks the spelling and the end-to-end runTask behaviour.

func TestReuseSpellingForPriorWorkdirPrefersRecordedSpellingOfSameDirectory(t *testing.T) {
	t.Parallel()

	realRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(realRoot, "workdir"), 0o755); err != nil {
		t.Fatalf("mkdir workdir: %v", err)
	}
	link := filepath.Join(t.TempDir(), "root-link")
	if err := os.Symlink(realRoot, link); err != nil {
		t.Fatalf("symlink root: %v", err)
	}

	recorded := filepath.Join(link, "workdir")
	validated := filepath.Join(realRoot, "workdir")
	if got := reuseSpellingForPriorWorkdir(recorded, validated); got != recorded {
		t.Fatalf("spelling = %q, want the recorded %q: both name the same directory", got, recorded)
	}
}

func TestReuseSpellingForPriorWorkdirFallsBackWhenRecordedMissing(t *testing.T) {
	t.Parallel()

	validated := t.TempDir()
	recorded := filepath.Join(t.TempDir(), "gone", "workdir")
	if got := reuseSpellingForPriorWorkdir(recorded, validated); got != validated {
		t.Fatalf("spelling = %q, want the validated %q when the recorded path does not exist", got, validated)
	}
}

func TestReuseSpellingForPriorWorkdirFallsBackWhenRecordedPointsElsewhere(t *testing.T) {
	t.Parallel()

	validated := t.TempDir()
	recorded := t.TempDir() // exists, but is a different directory
	if got := reuseSpellingForPriorWorkdir(recorded, validated); got != validated {
		t.Fatalf("spelling = %q, want the validated %q when the recorded path names another directory", got, validated)
	}
}

func TestReuseSpellingForPriorWorkdirCleansRecordedSpelling(t *testing.T) {
	t.Parallel()

	validated := t.TempDir()
	recorded := validated + string(filepath.Separator)
	if got := reuseSpellingForPriorWorkdir(recorded, validated); got != validated {
		t.Fatalf("spelling = %q, want the cleaned %q", got, validated)
	}
}

// TestRunTaskReuseKeepsPriorWorkdirSpelling is the end-to-end regression for
// sessions lost on resume. The daemon's WorkspacesRoot is reached through a
// symlink: the first task prepares under the link's spelling, while
// shouldReusePriorWorkdir resolves the prior workdir to the canonical
// target. Before the fix the follow-up ran in the canonical spelling, so an
// agent keying sessions by the raw cwd string could not find the session the
// first message created. The resumed task must run in the exact string the
// prior task ran in — directory identity alone is not enough.
func TestRunTaskReuseKeepsPriorWorkdirSpelling(t *testing.T) {
	t.Parallel()

	d, argsFile, cleanup := newLeaderReuseTestDaemon(t)
	defer cleanup()

	realRoot := d.cfg.WorkspacesRoot
	linkedRoot := filepath.Join(t.TempDir(), "root-link")
	if err := os.Symlink(realRoot, linkedRoot); err != nil {
		t.Fatalf("symlink workspaces root: %v", err)
	}
	d.cfg.WorkspacesRoot = linkedRoot

	first := leaderReuseTestTask("task-first")
	firstResult, err := d.runTask(context.Background(), first, "claude", 0, d.logger)
	if err != nil {
		t.Fatalf("first runTask: %v", err)
	}
	if firstResult.SessionID == "" || firstResult.WorkDir == "" {
		t.Fatalf("first result missing resume state: %+v", firstResult)
	}
	if !strings.HasPrefix(firstResult.WorkDir, linkedRoot+string(filepath.Separator)) {
		t.Fatalf("first WorkDir = %q, want it prepared under the linked root %q", firstResult.WorkDir, linkedRoot)
	}

	second := leaderReuseTestTask("task-second")
	second.PriorSessionID = firstResult.SessionID
	second.PriorWorkDir = firstResult.WorkDir
	secondResult, err := d.runTask(context.Background(), second, "claude", 0, d.logger)
	if err != nil {
		t.Fatalf("second runTask: %v", err)
	}
	// Exact string equality is the point: same directory in a different
	// spelling still loses the agent's session.
	if secondResult.WorkDir != firstResult.WorkDir {
		t.Fatalf("resumed task ran in %q, want the prior task's exact spelling %q", secondResult.WorkDir, firstResult.WorkDir)
	}

	args, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("read claude args: %v", err)
	}
	if !strings.Contains(string(args), "--resume\nsession-leader-reuse\n") {
		t.Fatalf("second claude invocation did not resume the prior session; args:\n%s", args)
	}
}
