#!/usr/bin/env bash
set -euo pipefail
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git init -q --bare "$root/base.git"
git init -q --bare "$root/contributor.git"
git init -q -b main "$root/seed"
git -C "$root/seed" config user.email researcher@example.invalid
git -C "$root/seed" config user.name "Research Lab"
printf '%s\n' 'base-original-branch-protected-in-concept' > "$root/seed/README.md"
git -C "$root/seed" add README.md
git -C "$root/seed" commit -qm baseline
git -C "$root/seed" remote add base "$root/base.git"
git -C "$root/seed" remote add contributor "$root/contributor.git"
git -C "$root/seed" push -q base main
git -C "$root/seed" push -q contributor main
git --git-dir="$root/base.git" symbolic-ref HEAD refs/heads/main
git --git-dir="$root/contributor.git" symbolic-ref HEAD refs/heads/main
# Build a harmless format patch whose destination is not under a protected branch.
git -C "$root/seed" switch -q -c pr-branch
printf '%s\n' 'synthetic autoformat output only' > "$root/seed/format-only.txt"
git -C "$root/seed" add format-only.txt
git -C "$root/seed" commit -qm 'lab: synthetic formatting'
git -C "$root/seed" format-patch --stdout HEAD~..HEAD > "$root/autoformat.patch"
git -C "$root/seed" reset -q --hard HEAD~
git -C "$root/seed" push -q contributor pr-branch
git -C "$root/seed" push -q base HEAD:refs/heads/internal-pr
# The actual upstream action selects github.event.workflow_run.head_repository.full_name.
git clone -q --branch pr-branch "$root/contributor.git" "$root/fork-checkout"
git -C "$root/fork-checkout" config user.email bot@example.invalid
git -C "$root/fork-checkout" config user.name "Research Lab Bot"
git -C "$root/fork-checkout" am --keep-cr < "$root/autoformat.patch" >/dev/null
git -C "$root/fork-checkout" push -q
git --git-dir="$root/contributor.git" show refs/heads/pr-branch:format-only.txt >/dev/null
if git --git-dir="$root/base.git" cat-file -e refs/heads/main:format-only.txt 2>/dev/null; then
  echo 'FORK_CASE_UNEXPECTED_BASE_MODIFICATION=true' >&2
  exit 1
fi
echo 'MAUI_HEAD_REPOSITORY_FORK_UPDATED=true'
echo 'MAUI_BASE_REPOSITORY_DEFAULT_BRANCH_UNCHANGED=true'
# A same-repository branch can be updated if repository write authority is present,
# while its default branch still stays unchanged without a merge.
git clone -q --branch internal-pr "$root/base.git" "$root/same-repo-checkout"
git -C "$root/same-repo-checkout" config user.email bot@example.invalid
git -C "$root/same-repo-checkout" config user.name "Research Lab Bot"
git -C "$root/same-repo-checkout" am --keep-cr < "$root/autoformat.patch" >/dev/null
git -C "$root/same-repo-checkout" push -q
git --git-dir="$root/base.git" show refs/heads/internal-pr:format-only.txt >/dev/null
if git --git-dir="$root/base.git" cat-file -e refs/heads/main:format-only.txt 2>/dev/null; then
  echo 'INTERNAL_CASE_UNEXPECTED_MAIN_MODIFICATION=true' >&2
  exit 1
fi
echo 'MAUI_SAME_REPO_PR_BRANCH_UPDATED=true'
echo 'MAUI_SAME_REPO_MAIN_UNCHANGED=true'
echo 'MAUI_HARNESS_LOCAL_GIT_ONLY=true'
echo 'MAUI_REAL_EXTERNAL_ACTION_EXECUTED=false'
