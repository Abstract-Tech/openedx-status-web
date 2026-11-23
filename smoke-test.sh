#!/usr/bin/env bash
# Smoke test for the status-web image, run the way production runs it (read-only root filesystem, all
# capabilities dropped, no-new-privileges, tmpfs mounts) with the real status-api behind it.
#
#   ./smoke-test.sh openedx-status-web:sec-test            # the image to test
#   ./smoke-test.sh ghcr.io/abstract-tech/openedx-status-web:0.1.2 > old.txt   # compare two images
#
# Needs Docker and curl. Prints PASS/FAIL per check, then "BEHAVIOUR" lines that are identical for two images
# that behave the same, so `diff old.txt new.txt` shows only real differences. Exit code 1 if any check fails.
set -u

IMAGE="${1:?usage: $0 <status-web image>}"
API_IMAGE="${API_IMAGE:-ghcr.io/abstract-tech/openedx-status-api:0.1.2}"
PORT="${PORT:-18080}"
ID="swt$$"
NET="$ID-net"
FAILS=0
TMP="$(mktemp -d)"

cleanup() {
  docker rm -f "$ID-web" "$ID-api" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  docker volume rm "$ID-data" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1  ($2)"; FAILS=$((FAILS + 1)); }
check() { # check "name" "expected" "actual"
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }
behave() { echo "BEHAVIOUR $*"; }

start_api() {
  docker run -d --name "$ID-api" --network "$NET" --network-alias status-api \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
    -e STATUS_HOST=0.0.0.0 -e STATUS_PORT=8000 -e STATUS_CHECKS_FILE=/config/checks.yml -e STATUS_DATA_DIR=/data \
    -v "$TMP/checks.yml:/config/checks.yml:ro" -v "$ID-data:/data" "$API_IMAGE" >/dev/null
}

cat > "$TMP/checks.yml" <<'EOF'
checks:
  - {id: self, name: Status page, group: Test, kind: http, target: "http://status-web:8080/healthz", interval: 5, timeout: 3}
EOF
chmod 644 "$TMP/checks.yml"

docker network create "$NET" >/dev/null
docker volume create "$ID-data" >/dev/null
start_api
docker run -d --name "$ID-web" --network "$NET" --network-alias status-web -p "127.0.0.1:$PORT:8080" \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp --tmpfs /var/cache/nginx --tmpfs /var/run \
  --tmpfs /var/cache/status-cache:uid=101,gid=101,mode=0755 "$IMAGE" >/dev/null

BASE="http://127.0.0.1:$PORT"
echo "== image: $IMAGE"
echo "== nginx: $(docker exec "$ID-web" nginx -v 2>&1)"

# 1. container comes up and is healthy
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$ID-web" 2>/dev/null)" = healthy ] && break
  sleep 1
done
check "container healthy (HEALTHCHECK)" healthy "$(docker inspect -f '{{.State.Health.Status}}' "$ID-web")"
check "runs as uid 101 (not root)" 101 "$(docker exec "$ID-web" id -u)"

# 2. static content
check "GET /healthz is 200" 200 "$(code "$BASE/healthz")"
check "GET /healthz body is ok" ok "$(curl -s "$BASE/healthz")"
check "GET / is 200" 200 "$(code "$BASE/")"
check "GET / returns the page" 1 "$(curl -s "$BASE/" | grep -c '<title>Status</title>')"
check "GET /assets/status.css is 200" 200 "$(code "$BASE/assets/status.css")"
check "css content-type" "text/css" "$(curl -sI "$BASE/assets/status.css" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}' | cut -d';' -f1)"
check "js content-type is javascript" 1 "$(curl -sI "$BASE/assets/status.js" | tr -d '\r' | grep -i '^content-type' | grep -c -i 'javascript')"
check "missing asset is 404 (not the index page)" 404 "$(code "$BASE/assets/nope.css")"
check "unknown path is 404" 404 "$(code "$BASE/nope")"
traversal="$(curl -s -m 10 --path-as-is "$BASE/assets/../../etc/passwd")"
tcode="$(code --path-as-is "$BASE/assets/../../etc/passwd")"
if [ "$tcode" = 200 ] || printf '%s' "$traversal" | grep -q 'root:'; then fail "path traversal is not served" "got $tcode"; else pass "path traversal is not served (HTTP $tcode)"; fi

# 3. security headers on every kind of response
for path in / /assets/status.css /api/status /nope; do
  h="$(curl -sI -m 10 "$BASE$path" | tr -d '\r' | tr 'A-Z' 'a-z')"
  for want in "x-content-type-options: nosniff" "referrer-policy: no-referrer" "content-security-policy: default-src 'self'"; do
    printf '%s' "$h" | grep -q "^$want" && pass "header '${want%%:*}' on $path" || fail "header '${want%%:*}' on $path" missing
  done
done

# 4. proxy to the API, including the stale-answer cache and DNS re-resolution
for _ in $(seq 1 20); do [ "$(code "$BASE/api/status")" = 200 ] && break; sleep 1; done
check "GET /api/status is 200 (proxy to status-api)" 200 "$(code "$BASE/api/status")"
check "API answer is JSON" 1 "$(curl -s "$BASE/api/status" | python3 -c 'import sys,json; json.load(sys.stdin); print(1)' 2>/dev/null)"
check "API answer has Cache-Control: no-store" "no-store" "$(curl -sI "$BASE/api/status" | tr -d '\r' | awk -F': ' 'tolower($1)=="cache-control"{print $2}')"

curl -s "$BASE/api/status" > "$TMP/before.json"
docker stop "$ID-api" >/dev/null
sleep 6   # longer than proxy_cache_valid (4s): only the stale-answer rule can serve this
check "API down: last good answer is still served" 200 "$(code "$BASE/api/status")"
check "API down: served answer is the cached one" "$(md5sum < "$TMP/before.json")" "$(curl -s "$BASE/api/status" | md5sum)"
check "API down: static page still works" 200 "$(code "$BASE/")"

docker rm -f "$ID-api" >/dev/null
start_api   # new container, new IP: nginx must pick it up by itself
ok=000
for _ in $(seq 1 40); do
  curl -s -m 5 "$BASE/api/status" | grep -q '"' && [ "$(code "$BASE/api/status")" = 200 ] && ok=200 && break
  sleep 1
done
check "API back: nginx re-resolved the new address" 200 "$ok"

# 5. HTTP/2 must stay off on this listener (the nginx CVEs in this release need it)
h2="$(curl -s -m 5 --http2-prior-knowledge -o /dev/null -w '%{http_code}' "$BASE/healthz" 2>/dev/null)"
if [ "$h2" = 200 ]; then fail "HTTP/2 is NOT enabled on the listener" "h2c worked"; else pass "HTTP/2 is NOT enabled on the listener"; fi
check "nginx config has no http2/ssl listener" 0 "$(docker exec "$ID-web" nginx -T 2>/dev/null | grep -c -E '^\s*(listen .*(http2|ssl)|http2 on)')"

# 6. no errors in the nginx log
errs="$(docker logs "$ID-web" 2>&1 | grep -c -E '\[(emerg|alert|crit)\]')"
check "no emerg/alert/crit lines in nginx log" 0 "$errs"

# Fingerprint: same for two images that behave the same (Server header and body of live data left out).
for path in / /healthz /assets/status.css /api/status /nope; do
  behave "$path" "$(code "$BASE$path")" "$(curl -sI "$BASE$path" | tr -d '\r' | tr 'A-Z' 'a-z' | grep -E '^(content-type|cache-control|x-content-type-options|referrer-policy|content-security-policy)' | sort | tr '\n' '|')"
done

echo
if [ "$FAILS" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: $FAILS check(s) FAILED"; fi
[ "$FAILS" -eq 0 ]
