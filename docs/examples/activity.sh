#!/bin/sh
# Create, update and end an activity with curl.
# Usage: MORPH_TOKEN=... [MORPH_PORT=47800] sh activity.sh
set -eu
API="http://127.0.0.1:${MORPH_PORT:-47800}/v1"
AUTH="Authorization: Bearer $MORPH_TOKEN"

curl -fsS -H "$AUTH" "$API/capabilities"; echo

curl -fsS -X POST "$API/activities" -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"id":"curl-001","title":"Enviando arquivo","subtitle":"Morph API","icon":"arrow.up","progress":0.1,"state":"running"}'
echo

curl -fsS -X PATCH "$API/activities/curl-001" -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"progress":0.65}'
echo

curl -fsS -X PATCH "$API/activities/curl-001" -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"progress":1,"state":"success"}'
echo

curl -fsS -X DELETE "$API/activities/curl-001" -H "$AUTH"
echo done
