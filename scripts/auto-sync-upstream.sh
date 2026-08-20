#!/usr/bin/env bash
# multica — daily upstream auto-sync & local service upgrade
#
# Flow:
#   1. fetch upstream; if there are new commits, merge upstream/main into main
#   2. gates: go build + views unit tests (web is gated by its docker build)
#   3. push the verified merge to origin (the fork)
#   4. deploy: pg backup -> rebuild binaries -> migrate -> restart server
#              -> rebuild & recreate the frontend container
#   5. file a multica issue summarizing the synced features + deploy result
#
# Safety rules:
#   - merge conflict           -> abort merge, report, exit (repo untouched)
#   - gate failure             -> reset merge, report, exit (nothing deployed)
#   - migration failure        -> exit BEFORE restarting the server
#   - server health failure    -> restore previous binary, restart, report
#   - frontend health failure  -> roll back to the previous image, report
#   - issue creation is best-effort; failures always land in the log file
#
# FORCE_DEPLOY=1 redeploys the current code even when upstream has no news.
set -uo pipefail

REPO=/data/sam.liux/workspace/multica
LOG_DIR=/data/sam.liux/multica-logs/auto-sync
BACKUP_DIR=/data/sam.liux/multica-logs/db-backups
STATUS_FILE="$LOG_DIR/last-status.json"
MULTICA_BIN="$REPO/server/bin/multica"
WORKSPACE_ID=b1d16988-e87b-4203-a359-494115cf6505
COMPOSE_FILES=(-f docker-compose.selfhost.yml -f docker-compose.selfhost.build.yml -f docker-compose.override.yml)

# go comes from miniconda on this box; cron gives us nothing, so be explicit.
export PATH="/home/sam.liux/.nvm/versions/node/v24.15.0/bin:/home/sam.liux/.local/bin:/home/sam.liux/miniconda3/bin:/usr/local/bin:/usr/bin:/bin"
export HOME=/home/sam.liux
export GOROOT=/home/sam.liux/miniconda3/go
export GOPROXY=https://goproxy.cn,direct
export GOTOOLCHAIN=auto
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export GIT_TERMINAL_PROMPT=0

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
RUN_LOG="$LOG_DIR/$(date +%F).log"
exec > >(tee -a "$RUN_LOG") 2>&1

log()  { echo "[$(date '+%F %T')] $*"; }
today() { date +%F; }

# Self-lock on a dedicated fd instead of a cron-level `flock` wrapper: the
# wrapper's lock fd is inherited by every child — including the API server
# this script restarts — which would hold the lock forever and silently
# wedge all future runs (exactly what happened on 2026-08-20).
LOCK="${MULTICA_SYNC_LOCK:-/tmp/multica-auto-sync.lock}"
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another auto-sync run is in progress; skipping"
  exit 0
fi

write_status() { # status stage detail
  printf '{"date":"%s","status":"%s","stage":"%s","detail":"%s"}\n' \
    "$(today)" "$1" "$2" "${3//\"/\\\"}" > "$STATUS_FILE"
}

file_issue() { # title; body on stdin. Best-effort.
  local title="$1"
  if ! command -v "$MULTICA_BIN" >/dev/null 2>&1; then
    log "issue skipped: multica CLI missing"
    return 0
  fi
  ( cd "$REPO" && MULTICA_WORKSPACE_ID="$WORKSPACE_ID" \
      "$MULTICA_BIN" issue create --title "$title" --description-stdin --output json ) \
    | head -5 || log "issue creation failed (see log)"
}

fail() { # stage detail
  local stage="$1" detail="$2"
  log "FAILED [$stage] $detail"
  write_status failed "$stage" "$detail"
  printf 'Auto-sync failed at stage `%s` on %s.\n\n```\n%s\n```\n\nFull log: `%s`\n' \
    "$stage" "$(today)" "$(echo "$detail" | tail -20)" "$RUN_LOG" \
    | file_issue "⚠️ Multica auto-sync FAILED at $stage ($(today))" || true
  exit 1
}

# ---------------------------------------------------------------- preflight
cd "$REPO" || { write_status failed preflight "repo missing"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail preflight "not on main branch"
if ! git diff --quiet || ! git diff --cached --quiet; then
  fail preflight "uncommitted tracked changes present — refusing to merge"
fi
sudo -n docker ps >/dev/null 2>&1 || fail preflight "passwordless 'sudo docker' unavailable"

PG_IP=$(sudo -n docker inspect multica-postgres-1 \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
[ -n "$PG_IP" ] || fail preflight "cannot resolve multica-postgres-1 container IP"
DB_URL="postgres://multica:multica@${PG_IP}:5432/multica?sslmode=disable"

# ---------------------------------------------------------------- sync
log "fetching upstream..."
git fetch upstream || fail fetch "git fetch upstream failed"

BEFORE=$(git rev-parse HEAD)
NEW_COMMITS=$(git rev-list --count HEAD..upstream/main)
MERGED=0

if [ "$NEW_COMMITS" -eq 0 ]; then
  if [ "${FORCE_DEPLOY:-0}" = "1" ]; then
    log "upstream has no new commits; FORCE_DEPLOY=1 -> redeploying current code"
  else
    log "already up to date with upstream ($BEFORE)"
    write_status up-to-date "" ""
    exit 0
  fi
else
  log "merging $NEW_COMMITS upstream commit(s)..."
  if ! MERGE_OUT=$(git merge upstream/main --no-edit 2>&1); then
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null | head -20)
    git merge --abort 2>/dev/null || true
    fail merge "conflict in: $(echo "$CONFLICTS" | tr '\n' ' ') — merge aborted, resolve manually"
  fi
  MERGED=1
  log "merge committed: $(git rev-parse --short HEAD)"
fi
AFTER=$(git rev-parse HEAD)
SYNC_RANGE="$BEFORE..$AFTER"

# changelog material (captured before any reset path)
# Matches "feat:", "feat(scope):", "MUL-123: feat: ..." and "MUL-123 fix(...)" styles.
FEAT_RE='^feat(\(|:|!)|[A-Z]+-[0-9]+(:| )+feat(\(|:|!)'
FIX_RE='^fix(\(|:|!)|[A-Z]+-[0-9]+(:| )+fix(\(|:|!)'
FEATURES=$(git log --format='- %s' "$SYNC_RANGE" | grep -E "$FEAT_RE" | head -30 || true)
FEATURE_COUNT=$(git log --format='%s' "$SYNC_RANGE" | grep -Ec "$FEAT_RE" || true)
FIX_COUNT=$(git log --format='%s' "$SYNC_RANGE" | grep -Ec "$FIX_RE" || true)
FIXES=$(git log --format='- %s' "$SYNC_RANGE" | grep -E "$FIX_RE" | head -30 || true)

# ---------------------------------------------------------------- gates
GATE_LOG=/tmp/multica-sync-gate.$$.log
if [ "$NEW_COMMITS" -gt 0 ]; then
  log "gate 1/3: pnpm install (frozen)..."
  if ! (cd "$REPO" && pnpm install --frozen-lockfile --prefer-offline) > "$GATE_LOG" 2>&1; then
    git reset --hard ORIG_HEAD
    fail deps "pnpm install failed; merge rolled back: $(tail -8 "$GATE_LOG")"
  fi

  log "gate 2/3: backend go build..."
  if ! (cd "$REPO/server" && timeout 900 go build ./...) > "$GATE_LOG" 2>&1; then
    git reset --hard ORIG_HEAD
    fail gate-build "go build failed; merge rolled back: $(tail -8 "$GATE_LOG")"
  fi

  log "gate 3/3: views unit tests..."
  if ! (cd "$REPO/packages/views" && timeout 1200 npx vitest run) > "$GATE_LOG" 2>&1; then
    git reset --hard ORIG_HEAD
    fail gate-test "views tests failed; merge rolled back: $(tail -15 "$GATE_LOG")"
  fi

  log "gates passed; pushing to origin..."
  git push origin main || fail push "git push origin main failed"
fi
rm -f "$GATE_LOG"

# ---------------------------------------------------------------- deploy
log "deploy: database backup..."
BACKUP_FILE="$BACKUP_DIR/multica-$(today).sql"
sudo -n docker exec multica-postgres-1 pg_dump -U multica multica > "$BACKUP_FILE" \
  || fail backup "pg_dump failed; aborting before any deploy step"
ls -1t "$BACKUP_DIR"/multica-*.sql 2>/dev/null | tail -n +8 | xargs -r rm -f
log "backup: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

log "deploy: building backend binaries..."
cp "$REPO/server/bin/server" "$REPO/server/bin/server.prev" 2>/dev/null || true
(cd "$REPO" && make build) || fail build "make build failed"
BACKEND_VERSION=$("$MULTICA_BIN" --version 2>/dev/null | head -1 || echo unknown)

log "deploy: applying migrations..."
MIGRATE_OUT=$( (cd "$REPO/server" && DATABASE_URL="$DB_URL" ./bin/migrate up 2>&1) ) \
  || fail migration "$(echo "$MIGRATE_OUT" | tail -5)"
MIGRATE_COUNT=$(echo "$MIGRATE_OUT" | grep -c '  up ' || true)
SCHEMA_NOW=$(sudo -n docker exec multica-postgres-1 psql -U multica -tAc \
  "select max(version) from schema_migrations;" 2>/dev/null | tr -d ' ')
log "migrations applied: $MIGRATE_COUNT (schema: $SCHEMA_NOW)"

log "deploy: restarting API server (preserving env)..."
SERVER_PID=$(pgrep -xf './server/bin/server' | head -1 || true)
if [ -z "$SERVER_PID" ]; then
  SERVER_PID=$(sudo -n ss -tlnp 2>/dev/null | grep ':8082 ' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
fi
[ -n "$SERVER_PID" ] || fail server "cannot find running server process on :8082"
cp "/proc/$SERVER_PID/environ" /tmp/multica-server.environ.$$ \
  || fail server "cannot read server environ"

python3 - "$SERVER_PID" /tmp/multica-server.environ.$$ "$REPO" <<'PY'
import os, sys, time
old_pid, env_file, repo = int(sys.argv[1]), sys.argv[2], sys.argv[3]
env = {}
with open(env_file, "rb") as f:
    for kv in f.read().split(b"\0"):
        if b"=" in kv:
            k, v = kv.split(b"=", 1)
            env[k.decode("utf-8", "surrogateescape")] = v.decode("utf-8", "surrogateescape")
for stale in ("_", "OLDPWD", "SHLVL", "TMPDIR", "TEMP", "TMP"):
    env.pop(stale, None)
env["PWD"], env["TMPDIR"] = repo, "/tmp"
try:
    os.kill(old_pid, 15)
except ProcessLookupError:
    pass
for _ in range(30):
    try:
        os.kill(old_pid, 0); time.sleep(0.5)
    except ProcessLookupError:
        break
else:
    sys.exit("old server did not exit")
time.sleep(1)
pid = os.fork()
if pid > 0:
    print(f"new server pid {pid}")
    sys.exit(0)
os.setsid(); os.chdir(repo)
log_fd = os.open("/data/sam.liux/multica-logs/server.log", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
null_fd = os.open("/dev/null", os.O_RDONLY)
os.dup2(null_fd, 0); os.dup2(log_fd, 1); os.dup2(log_fd, 2)
# Never leak inherited fds (sync-script lock fd!) into the long-lived server.
os.closerange(3, 1024)
os.execve(repo + "/server/bin/server", ["./server/bin/server"], env)
PY
[ $? -eq 0 ] || fail server "server restart spawn failed"
rm -f /tmp/multica-server.environ.$$

SERVER_OK=0
for i in $(seq 1 30); do
  curl -sf -o /dev/null http://127.0.0.1:8082/health && { SERVER_OK=1; break; }
  sleep 2
done
if [ "$SERVER_OK" -ne 1 ]; then
  log "server health check failed — rolling back to previous binary"
  if [ -f "$REPO/server/bin/server.prev" ]; then
    cp "$REPO/server/bin/server.prev" "$REPO/server/bin/server"
    NEW_PID=$(pgrep -xf './server/bin/server' | head -1 || true)
    [ -n "$NEW_PID" ] && kill "$NEW_PID" 2>/dev/null
    sleep 2
    # 9>&- : don't leak the sync lock fd into the rolled-back server either.
    (cd "$REPO" && nohup ./server/bin/server >> /data/sam.liux/multica-logs/server.log 2>&1 9>&- &)
  fi
  fail server "new server unhealthy after 60s; rolled back to previous binary"
fi
log "server healthy: $BACKEND_VERSION"

log "deploy: building frontend image (this takes minutes)..."
sudo -n docker tag multica-web:dev multica-web:prev 2>/dev/null || true
(cd "$REPO" && timeout 2400 sudo -n docker compose "${COMPOSE_FILES[@]}" build frontend) \
  || fail frontend-build "docker build failed; backend stays upgraded, frontend keeps old image"

log "deploy: recreating frontend container..."
(cd "$REPO" && sudo -n docker compose "${COMPOSE_FILES[@]}" up -d --no-deps frontend) \
  || fail frontend-up "docker compose up failed"
FRONTEND_OK=0
for i in $(seq 1 30); do
  curl -sf -o /dev/null http://127.0.0.1:80/ && { FRONTEND_OK=1; break; }
  sleep 2
done
if [ "$FRONTEND_OK" -ne 1 ]; then
  log "frontend unhealthy — rolling back to previous image"
  if sudo -n docker image inspect multica-web:prev >/dev/null 2>&1; then
    sudo -n docker tag multica-web:prev multica-web:dev
    (cd "$REPO" && sudo -n docker compose "${COMPOSE_FILES[@]}" up -d --no-deps frontend) || true
  fi
  fail frontend "frontend unhealthy after recreate; rolled back to previous image"
fi
log "frontend healthy on :80"

# ---------------------------------------------------------------- report
write_status success "" ""

if [ "$NEW_COMMITS" -gt 0 ]; then
  REPORT_FILE=/tmp/multica-sync-report.$$.md
  {
    echo "## ⬆️ Upstream sync $(today)"
    echo ""
    echo "同步上游 \`multica-ai/multica\` 更新并自动升级本地部署。"
    echo ""
    echo "- 提交范围: \`${BEFORE:0:9}\` → \`${AFTER:0:9}\`(共 **$NEW_COMMITS** 个提交;feat $FEATURE_COUNT / fix $FIX_COUNT)"
    echo "- 后端: \`$BACKEND_VERSION\`,server 已重启且 /health 正常"
    echo "- 数据库: 本次应用 **$MIGRATE_COUNT** 个迁移(schema: \`$SCHEMA_NOW\`),备份 \`$BACKUP_FILE\`"
    echo "- 前端: 镜像已重建并切换,http :80 正常"
    echo ""
    if [ -n "$FEATURES" ]; then
      echo "### ✨ 新增功能(feat)"
      echo "$FEATURES"
      [ "$FEATURE_COUNT" -gt 30 ] && echo "- … 其余 $((FEATURE_COUNT - 30)) 条见提交历史"
      echo ""
    fi
    if [ -n "$FIXES" ]; then
      echo "### 🐛 修复(fix)"
      echo "$FIXES"
      [ "$FIX_COUNT" -gt 30 ] && echo "- … 其余 $((FIX_COUNT - 30)) 条见提交历史"
      echo ""
    fi
    if [ -z "$FEATURES" ] && [ -z "$FIXES" ]; then
      echo "本次同步以 chore/docs/refactor 类提交为主,无 feat/fix。"
      echo ""
    fi
    echo "---"
    echo "_由每日 06:00 定时任务自动执行(scripts/auto-sync-upstream.sh),日志: \`$RUN_LOG\`_"
  } > "$REPORT_FILE"

  file_issue "Upstream sync $(today): +$NEW_COMMITS commits(feat $FEATURE_COUNT / fix $FIX_COUNT)" \
    < "$REPORT_FILE"
  rm -f "$REPORT_FILE"
  log "report issue filed"
fi

log "auto-sync completed successfully"
exit 0
