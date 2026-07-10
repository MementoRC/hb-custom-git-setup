#!/usr/bin/env bash
# Regenerate the squashed single-commit review branch `bleeding-edge-pr` from
# the current origin/bleeding-edge, parented on origin/modular, and force-push it.
#
# WHY: a review-friendly 1-commit view of the modular->bleeding-edge delta (the
# _for_bleed/* feature layer). The tree is byte-identical to bleeding-edge, so
# CI runs the same gates and any failing state is preserved, but reviewers/CI
# see a single commit instead of the full rebuild + merge history.
#
# WHEN: run AFTER bleeding-edge is pushed green. The pre-push gate calls this
# in-loop right after the bleeding-edge push. Uses `git commit-tree` so NO
# pre-commit hooks run and the tree is preserved byte-for-byte.
set -euo pipefail
REPO="${1:-/home/memento/PycharmProjects/Hummingbot/hummingbot}"
cd "$REPO"
git fetch origin --quiet
TREE=$(git rev-parse origin/bleeding-edge^{tree})
PARENT=$(git rev-parse origin/modular)
MSG="bleeding-edge snapshot for PR review ($(date +%Y-%m-%d)): squashed single-commit view of the modular->bleeding-edge delta (_for_bleed/* features). CI state preserved so the PR surfaces gate failures. Regenerated each rebuild; not a hand-merge target."
COMMIT=$(git commit-tree "$TREE" -p "$PARENT" -S -m "$MSG")
git push -f origin "${COMMIT}:refs/heads/bleeding-edge-pr"
echo "bleeding-edge-pr regenerated:"
echo "  commit:      $COMMIT"
echo "  tree:        $TREE  (== origin/bleeding-edge)"
echo "  parent:      $PARENT  (origin/modular)"
echo "  PR:          open bleeding-edge-pr -> modular on GitHub"
