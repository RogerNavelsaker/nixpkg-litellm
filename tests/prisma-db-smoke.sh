#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 IMAGE_REF" >&2
  exit 2
fi

image=$1
postgres_image=${POSTGRES_IMAGE:-docker.io/library/postgres@sha256:9770878138a2e83abcb10856d30cc3f24dae0d317bb956db6ab9159de6c3c80d}
startup_timeout=${STARTUP_TIMEOUT:-180}
if [[ ! $startup_timeout =~ ^[0-9]+$ ]] || (( startup_timeout < 1 )); then
  echo "STARTUP_TIMEOUT must be a positive integer" >&2
  exit 2
fi

cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}
mkdir -p "$cache_dir"
work=$(mktemp -d "$cache_dir/litellm-prisma-db.XXXXXX")
suffix=${work##*.}
network="litellm-prisma-db-$suffix"
db="litellm-prisma-db-$suffix"
app="litellm-prisma-app-$suffix"
db_password=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
master_key="sk-test-only-$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
salt_key="test-only-$(python3 -c 'import secrets; print(secrets.token_hex(24))')"

cleanup() {
  podman rm -fv "$app" "$db" >/dev/null 2>&1 || true
  podman network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

fail_with_logs() {
  local message=$1
  echo "FAIL: $message" >&2
  if podman container exists "$app"; then
    podman logs --timestamps "$app" > "$work/app.raw.log" 2>&1 || true
    echo '--- LiteLLM logs (secrets scrubbed) ---' >&2
    DB_PASSWORD="$db_password" MASTER_KEY="$master_key" SALT_KEY="$salt_key" \
      python3 - "$work/app.raw.log" <<'PY' >&2
import os, re, sys
from pathlib import Path
s = Path(sys.argv[1]).read_text(errors="replace")
for secret in (os.environ["DB_PASSWORD"], os.environ["MASTER_KEY"], os.environ["SALT_KEY"]):
    s = s.replace(secret, "[REDACTED]")
s = re.sub(r"postgres(?:ql)?://[^\s\"'<>]+", "postgresql://[REDACTED]", s, flags=re.I)
s = re.sub(r"(DATABASE_URL\s*[=:]\s*)[^\s,;]+", r"\1[REDACTED]", s, flags=re.I)
print(s[-20000:])
PY
    podman inspect "$app" --format 'container: running={{.State.Running}} exit_code={{.State.ExitCode}} error={{.State.Error}} oom_killed={{.State.OOMKilled}}' >&2 || true
  fi
  if [[ -s $work/readiness.json ]]; then
    echo '--- last readiness response ---' >&2
    cat "$work/readiness.json" >&2
  fi
  return 1
}

printf 'model_list: []\n' > "$work/config.yaml"
printf 'POSTGRES_USER=litellm\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=litellm\n' "$db_password" > "$work/db.env"
printf 'DATABASE_URL=postgresql://litellm:%s@postgres:5432/litellm?schema=public\nLITELLM_MASTER_KEY=%s\nLITELLM_SALT_KEY=%s\nLITELLM_LOCAL_MODEL_COST_MAP=true\n' \
  "$db_password" "$master_key" "$salt_key" > "$work/app.env"
chmod 600 "$work/db.env" "$work/app.env"

podman network create "$network" >/dev/null
podman run -d --name "$db" --network "$network" --network-alias postgres \
  --env-file "$work/db.env" "$postgres_image" >/dev/null
for _ in $(seq 1 90); do
  if podman exec "$db" pg_isready -U litellm -d litellm >/dev/null 2>&1; then break; fi
  if ! podman container exists "$db" || [[ $(podman inspect "$db" --format '{{.State.Running}}') != true ]]; then
    fail_with_logs 'disposable PostgreSQL exited before becoming ready'
  fi
  sleep 1
done
if ! podman exec "$db" pg_isready -U litellm -d litellm >/dev/null 2>&1; then
  fail_with_logs 'disposable PostgreSQL did not become ready within 90 seconds'
fi
pg_version=$(podman exec "$db" psql -U litellm -d litellm -Atc 'show server_version')
printf 'disposable PostgreSQL ready: %s\n' "$pg_version"

# Use the image's default entrypoint and command, just as a deployment does.
podman run -d --name "$app" --network "$network" --env-file "$work/app.env" \
  -v "$work/config.yaml:/etc/litellm/config.yaml:ro" "$image" >/dev/null
ready=0
for _ in $(seq 1 "$startup_timeout"); do
  if [[ $(podman inspect "$app" --format '{{.State.Running}}' 2>/dev/null || echo false) != true ]]; then
    fail_with_logs 'LiteLLM exited before database readiness'
  fi
  if podman exec "$app" python -c 'import json,urllib.error,urllib.request; u="http://127.0.0.1:4000/health/readiness";
try: r=urllib.request.urlopen(u,timeout=2)
except urllib.error.HTTPError as e: r=e
print(json.dumps({"http_status":r.code,"body":r.read(8192).decode("utf-8","replace")}))' \
    > "$work/readiness.json" 2>/dev/null; then
    if python3 - "$work/readiness.json" <<'PY'
import json, sys
probe = json.load(open(sys.argv[1]))
body = json.loads(probe["body"])
raise SystemExit(0 if probe["http_status"] == 200 and body.get("status") == "healthy" and str(body.get("db", "")).lower() == "connected" else 1)
PY
    then
      ready=1
      break
    fi
  fi
  sleep 1
done
if (( ! ready )); then
  fail_with_logs "LiteLLM did not report HTTP 200 with status=healthy and db=connected within ${startup_timeout}s"
fi
printf 'LiteLLM readiness: '
cat "$work/readiness.json"
migration_count=$(podman exec "$db" psql -U litellm -d litellm -Atc 'select count(*) from "_prisma_migrations"')
if [[ ! $migration_count =~ ^[0-9]+$ ]] || (( migration_count == 0 )); then
  fail_with_logs 'LiteLLM did not apply Prisma migrations to the disposable database'
fi
printf 'applied Prisma migrations: %s\n' "$migration_count"

cat > "$work/prisma-probe.py" <<'PY'
import asyncio, json, os, traceback
import prisma.client as client_module
from prisma import Prisma
original = client_module.deserialize_raw_results
def capture(raw, *args, **kwargs):
    shape = {
        "keys": sorted(raw) if isinstance(raw, dict) else None,
        "columns": raw.get("columns") if isinstance(raw, dict) else None,
        "types": raw.get("types") if isinstance(raw, dict) else None,
        "rows": raw.get("rows") if isinstance(raw, dict) else None,
    }
    print("RAW_RESULT_BEFORE_DECODER=" + json.dumps(shape, default=str), flush=True)
    try:
        return original(raw, *args, **kwargs)
    except BaseException:
        print("DECODER_TRACEBACK_BEGIN", flush=True)
        traceback.print_exc()
        print("DECODER_TRACEBACK_END", flush=True)
        raise
client_module.deserialize_raw_results = capture
async def main():
    prisma = Prisma()
    try:
        await prisma.connect()
        engine = prisma._engine
        process = engine.process
        assert process is not None and process.poll() is None, "Prisma query-engine did not remain ready"
        print(f"QUERY_ENGINE_READY pid={process.pid} executable={os.environ['PRISMA_QUERY_ENGINE_BINARY']}", flush=True)
        result = await prisma.query_raw("SELECT 1 AS one")
        assert result == [{"one": 1}], result
        print("RAW_QUERY_DECODED=" + json.dumps(result), flush=True)
    finally:
        await prisma.disconnect()
asyncio.run(main())
PY
printf 'Prisma query-engine and SELECT 1 probe:\n'
podman exec "$app" python -c "$(cat "$work/prisma-probe.py")"
echo 'PASS: database-backed LiteLLM readiness and Prisma raw-query smoke test'
