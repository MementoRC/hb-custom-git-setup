#!/usr/bin/env bash
# Regenerate the squashed single-commit review branch `ci-base-pr` from the
# current origin/ci-base, parented on origin/development, and force-push it.
#
# WHY: PR #68 (ci-base-pr -> development) is a review-friendly 1-commit view of
# the same delta as PR #67 (ci-base -> development). Its tree is byte-identical
# to ci-base, so CI runs the same gates and the failing state is preserved, but
# reviewers see a single commit instead of the full rebuild history.
#
# WHEN: run this AFTER you push ci-base (the rebuild script is zero-push by
# design, so this is part of the manual post-rebuild push step). It uses
# `git commit-tree` so NO pre-commit hooks run and the failing tree is preserved
# byte-for-byte.
set -euo pipefail
REPO="${1:-/home/memento/PycharmProjects/Hummingbot/hummingbot}"
cd "$REPO"
git fetch origin --quiet
TREE=$(git rev-parse origin/ci-base^{tree})
PARENT=$(git rev-parse origin/development)
MSG="ci-base snapshot for PR review ($(date +%Y-%m-%d)): squashed single-commit view of the development->ci-base delta. CI-failing state preserved so the PR surfaces gate failures. Regenerated each rebuild; not a hand-merge target."
COMMIT=$(git commit-tree "$TREE" -p "$PARENT" -S -m "$MSG")
git push -f origin "${COMMIT}:refs/heads/ci-base-pr"
echo "ci-base-pr regenerated:"
echo "  commit:      $COMMIT"
echo "  tree:        $TREE  (== origin/ci-base)"
echo "  parent:      $PARENT  (origin/development)"
echo "  PR:          https://github.com/MementoRC/hummingbot/pull/68"
