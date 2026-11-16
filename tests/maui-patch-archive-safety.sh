#!/usr/bin/env bash
set -euo pipefail
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/repo"
git -C "$t/repo" init -q
git -C "$t/repo" config user.email lab@example.invalid
git -C "$t/repo" config user.name Lab
echo "baseline" > "$t/repo/README.md"
git -C "$t/repo" add README.md
git -C "$t/repo" commit -qm baseline
echo "synthetic formatted change" > "$t/repo/scope.txt"
git -C "$t/repo" add scope.txt
git -C "$t/repo" commit -qm 'lab scope patch'
git -C "$t/repo" format-patch --stdout HEAD~..HEAD > "$t/valid.patch"
git -C "$t/repo" reset -q --hard HEAD~
(
  cd "$t/repo"
  git am --keep-cr < "$t/valid.patch" >/dev/null
)
test -f "$t/repo/scope.txt"
echo "MAUI_LOCAL_PATCH_REGULAR_APPLY_PASS=true"
python3 - "$t/valid.patch" "$t/path-escape.patch" <<'PY'
import sys
from pathlib import Path
data=Path(sys.argv[1]).read_text()
assert 'scope.txt' in data
Path(sys.argv[2]).write_text(data.replace('scope.txt','../OUTSIDE_ONLY_IN_LAB.txt'))
PY
if ( cd "$t/repo" && git am --keep-cr < "$t/path-escape.patch" ) > "$t/denied.log" 2>&1; then
  echo 'MAUI_PATH_TRAVERSAL_PATCH_UNEXPECTEDLY_APPLIED=true'
  exit 1
fi
test ! -f "$t/OUTSIDE_ONLY_IN_LAB.txt"
test ! -f "$t/repo/../OUTSIDE_ONLY_IN_LAB.txt"
echo "MAUI_LOCAL_PATCH_PARENT_TRAVERSAL_REJECTED=true"
git -C "$t/repo" am --abort >/dev/null 2>&1 || true
mkdir -p "$t/zip_dest"
python3 - "$t/zip-payload.zip" <<'PY'
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w') as f:
  f.writestr('../../OUTSIDE_ZIP_ONLY_IN_LAB.txt','safe marker')
  f.writestr('safe/readme.txt','inert')
PY
unzip -q -d "$t/zip_dest" "$t/zip-payload.zip" > "$t/unzip.log" 2>&1 || true
test ! -f "$t/OUTSIDE_ZIP_ONLY_IN_LAB.txt"
test ! -f "$t/../OUTSIDE_ZIP_ONLY_IN_LAB.txt"
echo "MAUI_UNZIP_PARENT_ESCAPE_NOT_OBSERVED=true"
echo "GITHUB_API_WRITES=false"
echo "PRIVILEGED_EXTERNAL_ACTION_EXECUTED=false"
