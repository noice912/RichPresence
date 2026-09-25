#!/usr/bin/env bash
# Runs a Gradle task and, if it fails, turns compiler errors and failed tests into GitHub annotations.
cd "$(dirname "$0")"
gradle --no-daemon "$@" > gradle.log 2>&1
code=$?
cat gradle.log
if [ $code -ne 0 ]; then
  grep -E '^e: |error:|FAILED|Exception|expected:|What went wrong' -A2 gradle.log | head -40 | while IFS= read -r l; do
    echo "::error title=gradle::${l:0:900}"
  done
  for f in app/build/test-results/*/*.xml; do
    [ -f "$f" ] && grep -o '<failure message="[^"]*"' "$f" | head -10 | sed 's/^/::error title=test::/'
  done
fi
exit $code
