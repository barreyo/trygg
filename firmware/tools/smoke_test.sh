#!/usr/bin/env bash
# Exercises the same API calls the M5Stack makes, from this Mac, using the URL and
# token in include/config.h. Logs one real pee/poo/mixed entry each (delete them
# in the app afterwards) unless called with --read-only.
set -euo pipefail

cfg="$(cd "$(dirname "$0")/.." && pwd)/include/config.h"
url=$(sed -n 's/^#define TRYGG_URL "\(.*\)"/\1/p' "$cfg")
token=$(sed -n 's/^#define TRYGG_TOKEN "\(.*\)"/\1/p' "$cfg")
child=$(sed -n 's/^#define TRYGG_CHILD_ID \([0-9]*\).*/\1/p' "$cfg")
auth="Authorization: Bearer $token"

echo "GET $url/api/v1/children"
children=$(curl -fsS -H "$auth" "$url/api/v1/children")
echo "$children"
[ "${1:-}" = "--read-only" ] && exit 0

[ "$child" = "0" ] && child=$(echo "$children" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for kind in pee poo mixed; do
  id=$(uuidgen | tr A-Z a-z)
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"type\":\"diaper\",\"data\":{\"kind\":\"$kind\"},\"started_at\":\"$now\",\"client_id\":\"$id\"}" \
    "$url/api/v1/children/$child/entries")
  echo "POST $kind -> $code"
done
