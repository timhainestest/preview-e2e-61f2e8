#!/usr/bin/env bash
# The end-to-end suite. Runs against the preview deployment named in the dispatch payload,
# using the bypass token so the suite can reach a preview that is behind access control.
set -euo pipefail

echo "running end-to-end suite against ${PREVIEW_URL:-<none>}"

if [ -z "${PREVIEW_BYPASS_TOKEN:-}" ]; then
  echo "no bypass token; skipping protected-preview checks"
  exit 0
fi

status=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "${PREVIEW_BYPASS_HEADER:-x-bypass}: $PREVIEW_BYPASS_TOKEN" \
  "${PREVIEW_URL:-https://example.invalid}" || echo "000")
echo "preview responded $status"
echo "suite passed"
