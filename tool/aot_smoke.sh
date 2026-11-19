#!/bin/bash
# AOT smoke: `dart compile exe bin/server.dart`, then the binary and `dart run bin/server.dart` (JIT) each on a fresh
# database — /health 200, sign-in (+ the forced password change), six panel pages, a CRUD round-trip through the ORM
# (@Action package_add → listed → package_delete) — and the rendered pages of both must be identical.
# Postgres + Redis: the cluster of tool/pg_test.sh (run it once first). Prints binary size and time to /health 200.
#   tool/aot_smoke.sh            IGNIS_PG_DIR / IGNIS_PG_PORT / IGNIS_PG_REDIS_PORT / SMOKE_PORT as in pg_test.sh
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
P=${IGNIS_PG_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ignis-pg}; PORT=${IGNIS_PG_PORT:-55433}; RPORT=${IGNIS_PG_REDIS_PORT:-56379}
B=$(ls -d "$P"/npm/node_modules/@embedded-postgres/linux-*/native 2>/dev/null | head -1)
[ -x "$B/bin/postgres" ] || { echo "no Postgres in $P — run tool/pg_test.sh once first"; exit 1; }
export LD_LIBRARY_PATH=$B/lib
$B/bin/pg_ctl -D $P/data status >/dev/null 2>&1 || $B/bin/pg_ctl -D $P/data -o "-p $PORT -k $P" -l $P/pg.log -w start >/dev/null || exit 1
redis-cli -p $RPORT ping >/dev/null 2>&1 || redis-server --port $RPORT --save '' --appendonly no --daemonize yes >/dev/null || exit 1

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
dart compile exe bin/server.dart -o "$W/server" >/dev/null || exit 1
echo "binary: $(stat -c %s "$W/server") bytes ($(du -h "$W/server" | cut -f1))"
# an AOT binary has no package config: the package's templates/, i18n/, web/ go next to it
mkdir -p "$W/pkg" "$W/run" && cp -r templates i18n web "$W/pkg/"

H="Host: localhost"; PASS='Smoke-Test-Pass-123!'; NEW='Smoke-Changed-Pass-456!'
fail=0
run() { # label, command…
  local label=$1; shift
  redis-cli -p $RPORT flushall >/dev/null
  IGNIS_DB_HOST=127.0.0.1 IGNIS_DB_PORT=$PORT IGNIS_DB_USER=ig IGNIS_DB_PASS=ig IGNIS_DB_NAME=postgres \
    dart run tool/pg_new_db.dart ignistest ignis_app ignisapp ignis_rt ignisrt >/dev/null || exit 1
  local port=${SMOKE_PORT:-18080} J="$W/$label.jar" t0 t1 c pid
  t0=$(date +%s%N)
  (cd "$W/run" && exec env IGNIS_DB_HOST=127.0.0.1 IGNIS_DB_PORT=$PORT IGNIS_DB_NAME=ignistest IGNIS_DB_USER=ignis_app \
    IGNIS_DB_PASS=ignisapp IGNIS_REDIS_HOST=127.0.0.1 IGNIS_REDIS_PORT=$RPORT IGNIS_DOMAINS=localhost \
    IGNIS_KEY=$(printf '0123456789abcdef%.0s' {1..4}) IGNIS_TRUSTED_PROXIES=none IGNIS_PORT=$port \
    IGNIS_ADMIN_PASS="$PASS" IGNIS_PACKAGE_ROOT="$W/pkg" "$@") > "$W/$label.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 1200); do
    c=$(curl -s -H "$H" -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/health); [ "$c" = 200 ] && break; sleep 0.05
  done
  t1=$(date +%s%N)
  echo "$label: /health $c after $(( (t1 - t0) / 1000000 )) ms"
  [ "$c" = 200 ] || { fail=1; tail -20 "$W/$label.log"; kill $pid; return; }
  u=http://127.0.0.1:$port; cs() { grep ignis_csrf "$J" | awk '{print $7}'; }
  post() { curl -s -H "$H" -c "$J" -b "$J" -o /dev/null -w '%{http_code}' --data-urlencode "csrf=$(cs)" "${@:2}" "$u$1"; }
  login() { curl -s -H "$H" -c "$J" -b "$J" -o /dev/null "$u/admin/login"; post /admin/login --data-urlencode username=admin --data-urlencode "password=$1"; }
  local a b d e
  a=$(login "$PASS")
  b=$(post /admin/account --data-urlencode triggerAction=password --data-urlencode "old_password=$PASS" \
    --data-urlencode "new_password=$NEW" --data-urlencode "repeat_password=$NEW")
  c=$(login "$NEW")
  echo "$label: sign-in $a, password change $b, sign-in again $c"
  mkdir -p "$W/$label.pages"
  for r in /admin /admin/permissions /admin/settings /admin/account /admin/audit-log /admin/files; do
    c=$(curl -s -H "$H" -c "$J" -b "$J" -o "$W/$label.pages/${r//\//_}.html" -w '%{http_code}' "$u$r")
    echo "$label: GET $r $c"; [ "$c" = 200 ] || fail=1
  done
  a=$(post /admin/permissions --data-urlencode triggerAction=package_add --data-urlencode "name=Smoke Pkg")
  b=$(curl -s -H "$H" -c "$J" -b "$J" "$u/admin/permissions" | grep -c 'Smoke Pkg')
  d=$(post /admin/permissions --data-urlencode triggerAction=package_delete --data-urlencode id=smoke-pkg)
  e=$(curl -s -H "$H" -c "$J" -b "$J" "$u/admin/permissions" | grep -c 'Smoke Pkg')
  echo "$label: CRUD add $a → listed $b, delete $d → listed $e"
  [ "$b" -ge 1 ] && [ "$e" = 0 ] || fail=1
  kill $pid; wait $pid 2>/dev/null
}
run aot "$W/server"
run jit dart run "$ROOT/bin/server.dart"
norm() { sed -E 's/(nonce|csrf|value)="[^"]*"/\1="X"/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:.]+/TS/g; s/[0-9a-f]{16,}/H/g' "$1"; }
for f in "$W"/aot.pages/*.html; do
  if diff <(norm "$f") <(norm "$W/jit.pages/$(basename "$f")") >/dev/null; then echo "same page AOT/JIT: $(basename "$f")"
  else echo "DIFFERENT page AOT/JIT: $(basename "$f")"; fail=1; fi
done
[ $fail = 0 ] && echo "AOT SMOKE OK" || echo "AOT SMOKE FAILED"
exit $fail
