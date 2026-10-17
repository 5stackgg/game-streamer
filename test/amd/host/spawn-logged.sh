#!/usr/bin/env bash
# S3-U18: no terminal; tini reaps the detached logger after its launcher exits.
set -euo pipefail
if [ "${1:-}" = --inside ]; then
  export LOG_DIR=/tmp/gs-logging
  mkdir -p "$LOG_DIR"
  bash -c 'set -uo pipefail
    . /src/src/lib/xorg.sh
    _spawn_logged_to stub "$LOG_DIR/stub.log" bash -c '\''for ((i=1;i<=12;i++)); do
      printf "line-%02d\n" "$i"; sleep 1
    done
    sleep 600'\''
    printf "%s\n" "$SPAWNED_PID" > "$LOG_DIR/server.pid"
  '
  printf 'launcher-exited\n'
  sleep 60
  exit 0
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cid=''
trap '[ -z "$cid" ] || docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
cid=$(docker run -d --init --platform linux/amd64 -v "$root:/src:ro" -w /src \
  ubuntu:24.04 bash test/amd/host/spawn-logged.sh --inside)
for ((i=0;i<30;i++)); do
  text=$(docker logs "$cid" 2>&1)
  grep -q launcher-exited <<< "$text" && break
  sleep 0.1
done
grep -q launcher-exited <<< "$text"
# At each sample, every line older than two seconds must already be tagged and raw.
for ((i=1;i<=10;i++)); do
  sleep 1
  text=$(docker logs "$cid" 2>&1)
  raw=$(docker exec "$cid" cat /tmp/gs-logging/stub.log)
  k=$((i-1))
  if [ "$k" -gt 0 ]; then
    line=$(printf 'line-%02d' "$k")
    grep -qF "[stub] $line" <<< "$text"
    grep -qxF "$line" <<< "$raw"
  fi
done
docker exec "$cid" bash -c 'kill -0 "$(cat /tmp/gs-logging/server.pid)"'
sleep 3
docker exec "$cid" bash -c 'kill "$(cat /tmp/gs-logging/server.pid)"'
for ((i=0;i<50;i++)); do
  text=$(docker logs "$cid" 2>&1)
  grep -qF '[stub] line-12' <<< "$text" && break
  sleep 0.1
done
for ((i=1;i<=12;i++)); do
  grep -qF "[stub] $(printf 'line-%02d' "$i")" <<< "$text"
done
printf 'S3-U18: 12 raw and tagged lines survive launcher exit\n'
