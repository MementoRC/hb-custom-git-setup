#!/usr/bin/env bash
# Dry-run of the ci-base -> modular merge conflict classification.
# Usage (from the hummingbot checkout, needs ruff + yq on PATH):
#   cd /home/memento/PycharmProjects/Hummingbot/hummingbot && \
#     pixi run -e ci bash ../custom_git_setup/scripts/tests/dry_run_modular_merge.sh [ours_ref] [theirs_ref]
# Defaults: origin/modular origin/ci-base. Override the modular_owned_paths
# config with BRANCH_CONFIG=<file> (default: custom_git_setup/configs/branch-tracking.yaml).
#
# Merges in a temp DETACHED worktree only; the main checkout, its HEAD and all
# refs are never touched. Nothing is committed or pushed.
# Exit 1 if any conflicted file is LOGICAL, else 0.
set -u

OURS_REF="${1:-origin/modular}"
THEIRS_REF="${2:-origin/ci-base}"

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"
BRANCH_CONFIG="${BRANCH_CONFIG:-$(cd "$(dirname "$SCRIPT")/.." && pwd)/configs/branch-tracking.yaml}"

REPO="$(git rev-parse --show-toplevel)" || { echo "not in a git repo"; exit 2; }
WT="$(mktemp -d)" || exit 2

cleanup() {
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
    rm -rf "$WT"
}
trap cleanup EXIT

log_detail() { :; }
for fn in ci_base_generated_path read_modular_owned_paths modular_owns_path \
          conflict_is_format_only conflict_gitignore_pattern_subset \
          conflict_side_is_subset conflict_ci_base_is_subset conflict_modular_is_subset \
          conflict_regions_variant conflict_regions_style_only; do
    # shellcheck disable=SC1090
    source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
done

git -C "$REPO" worktree add -q --detach "$WT" "$OURS_REF" || { echo "worktree add failed"; exit 2; }
cd "$WT" || exit 2

# Conflicts are expected; fail-open.
git merge --no-commit --no-ff "$THEIRS_REF" >/dev/null 2>&1 || true

n_generated=0; n_owned=0; n_fmt=0; n_subset=0; n_msubset=0; n_regions=0; n_logical=0
logical_files=()
while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
        pyproject.toml|.pre-commit-config.yaml|conftest.py|.github/*|test/conftest.py)
            v="LOGICAL"; n_logical=$((n_logical + 1)) ;;
        *)
            if ci_base_generated_path "$file"; then
                v="generated(theirs)"; n_generated=$((n_generated + 1))
            elif modular_owns_path "$file"; then
                v="modular-owned"; n_owned=$((n_owned + 1))
            elif conflict_is_format_only "$file"; then
                v="format-only(theirs)"; n_fmt=$((n_fmt + 1))
            elif conflict_ci_base_is_subset "$file"; then
                v="ci-base-subset(ours)"; n_subset=$((n_subset + 1))
            elif conflict_modular_is_subset "$file"; then
                v="modular-subset(theirs)"; n_msubset=$((n_msubset + 1))
            elif conflict_regions_style_only "$file"; then
                v="style-regions(theirs)"; n_regions=$((n_regions + 1))
            else
                v="LOGICAL"; n_logical=$((n_logical + 1))
            fi ;;
    esac
    echo "$v $file"
    [ "$v" = "LOGICAL" ] && logical_files+=("$file")
done < <(git diff --name-only --diff-filter=U)

echo "SUMMARY generated=$n_generated modular-owned=$n_owned format-only=$n_fmt ci-base-subset=$n_subset modular-subset=$n_msubset style-regions=$n_regions LOGICAL=$n_logical"
for f in "${logical_files[@]}"; do echo "LOGICAL $f"; done
git merge --abort >/dev/null 2>&1 || true
[ "$n_logical" -eq 0 ]
