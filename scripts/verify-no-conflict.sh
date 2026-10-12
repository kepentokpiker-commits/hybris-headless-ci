#!/usr/bin/env bash
set -euo pipefail
DIR="${1:?folder .deb}"
fail=0
for f in "$DIR"/*.deb; do
  echo "--- $(basename "$f")"
  dpkg-deb -f "$f" Replaces Conflicts Breaks | grep -q . \
    && { echo "PERINGATAN: ada Replaces/Conflicts/Breaks"; fail=1; } || true
  while read -r path; do
    p="${path#.}"
    [ -f "$p" ] || [ -L "$p" ] || continue
    if owner=$(dpkg -S "$p" 2>/dev/null); then
      echo "BENTROK: $p dimiliki ${owner%%:*}"; fail=1
    fi
  done < <(dpkg-deb -c "$f" | awk '$1 !~ /^d/ {print $6}')
done
exit $fail
