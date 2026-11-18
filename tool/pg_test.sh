#!/bin/bash
# Tests on a real Postgres (no Docker or root): binaries from npm @embedded-postgres (pinned version),
# cluster in a private user directory (~/.cache/ignis-pg by default, 0700 — not in /tmp, where another user
# could plant binaries), port 55433, database ignistest (owner: a regular role ignis_app, no BYPASSRLS)
# dropped on every run. Local Redis (redis-server) on 56379.
#   tool/pg_test.sh [test file …]   (test/*_pg_test.dart by default)
#   IGNIS_PG_DIR / IGNIS_PG_PORT / IGNIS_PG_REDIS_PORT — a second cluster alongside (e.g. a parallel worktree)
cd "$(dirname "$0")/.." || exit 1
P=${IGNIS_PG_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ignis-pg}; PORT=${IGNIS_PG_PORT:-55433}; RPORT=${IGNIS_PG_REDIS_PORT:-56379}
PG_NPM=18.6.0-beta.19
mkdir -p -m 700 "$P" || exit 1
if [ ! -O "$P" ] || [ -L "$P" ] || [ -n "$(find "$P" -maxdepth 0 -perm /077)" ]; then
  echo "$P: the directory must be mine, not a symlink, with no rights for others (chmod 700)"; exit 1
fi
arch=$(uname -m); [ "$arch" = aarch64 ] && arch=arm64; [ "$arch" = x86_64 ] && arch=x64
M=$P/npm/node_modules/@embedded-postgres/linux-$arch; B=$M/native
if [ ! -x "$B/bin/postgres" ] || ! grep -q "\"version\": \"$PG_NPM\"" "$M/package.json"; then
  # --ignore-scripts: no code from the registry at install time; the package's postinstall only restores lib/ links
  mkdir -p "$P/npm" && (cd "$P/npm" && npm init -y >/dev/null &&
    npm install --silent --ignore-scripts --save-exact "@embedded-postgres/linux-$arch@$PG_NPM") || exit 1
  node "$M/scripts/hydrate-symlinks.js" || exit 1
  chmod +x "$B"/bin/*
fi
export LD_LIBRARY_PATH=$B/lib
if [ ! -d $P/data ]; then
  (umask 077 && echo ig > $P/pw) && $B/bin/initdb -D $P/data -U ig --pwfile=$P/pw -A scram-sha-256 >/dev/null || exit 1
fi
$B/bin/pg_ctl -D $P/data status >/dev/null 2>&1 || $B/bin/pg_ctl -D $P/data -o "-p $PORT -k $P" -l $P/pg.log -w start >/dev/null || exit 1
redis-cli -p $RPORT ping >/dev/null 2>&1 || redis-server --port $RPORT --save '' --appendonly no --daemonize yes >/dev/null || exit 1
redis-cli -p $RPORT flushall >/dev/null
export IGNIS_DB_HOST=127.0.0.1 IGNIS_DB_PORT=$PORT IGNIS_DB_USER=ig IGNIS_DB_PASS=ig IGNIS_DB_NAME=postgres
dart run tool/pg_new_db.dart ignistest ignis_app ignisapp || exit 1
export IGNIS_DB_NAME=ignistest IGNIS_DB_USER=ignis_app IGNIS_DB_PASS=ignisapp IGNIS_REDIS_HOST=127.0.0.1 IGNIS_REDIS_PORT=$RPORT
export IGNIS_DOMAINS=${IGNIS_DOMAINS:-localhost}
export IGNIS_KEY=${IGNIS_KEY:-$(printf '0123456789abcdef%.0s' {1..4})}
bad=0
for t in ${@:-test/*_pg_test.dart}; do
  timeout -k 10 ${IGNIS_TEST_TIMEOUT:-300} dart run "$t" > $P/t.log 2>&1; r=$?
  if [ $r -ne 0 ] || grep -qE "NOT PASSED|Unhandled exception" $P/t.log; then
    bad=$((bad+1)); echo "FAIL $t (exit $r)"; grep -E "NIE|exception|Error" $P/t.log | head -8
  else
    echo "ok $t"
  fi
done
exit $bad
