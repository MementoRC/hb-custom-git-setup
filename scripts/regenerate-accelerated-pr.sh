#!/usr/bin/env bash
# Regenerate the squashed single-commit review branch `accelerated-pr` from
# the current origin/accelerated, parented on origin/bleeding-edge, and force-push it.
#
# WHY: a review-friendly 1-commit view of the bleeding-edge->accelerated delta
# (the _for_accel/* compiled-extension layer: Rust, Cython). The tree is
# byte-identical to accelerated, so CI runs the same gates and any failing state
# is preserved, but reviewers/CI see a single commit instead of the full rebuild
# + merge history.
#
# WHEN: run AFTER accelerated is pushed green. The pre-push gate calls this
# in-loop right after the accelerated push. Uses `git commit-tree` so NO
# pre-commit hooks run and the tree is preserved byte-for-byte.
set -euo pipefail
REPO="${1:-/home/memento/PycharmProjects/Hummingbot/hummingbot}"
cd "$REPO"
git fetch origin --quiet
TREE=$(git rev-parse origin/accelerated^{tree})
PARENT=$(git rev-parse origin/bleeding-edge)
MSG="accelerated snapshot for PR review ($(date +%Y-%m-%d)): squashed single-commit view of the bleeding-edge->accelerated delta (_for_accel/* compiled-extension work). CI state preserved so the PR surfaces gate failures. Regenerated each rebuild; not a hand-merge target."
COMMIT=$(git commit-tree "$TREE" -p "$PARENT" -S -m "$MSG")
git push -f origin "${COMMIT}:refs/heads/accelerated-pr"
echo "accelerated-pr regenerated:"
echo "  commit:      $COMMIT"
echo "  tree:        $TREE  (== origin/accelerated)"
echo "  parent:      $PARENT  (origin/bleeding-edge)"
echo "  PR:          open accelerated-pr -> bleeding-edge on GitHub"
