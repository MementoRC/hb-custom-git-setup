#!/usr/bin/env bash
# Regenerate the squashed single-commit review branch `modular-pr` from the
# current origin/modular, parented on origin/ci-base, and force-push it.
#
# WHY: a review-friendly 1-commit view of the ci-base->modular delta (the
# sub-package wiring layer). The tree is byte-identical to modular, so CI runs
# the same gates and any failing state is preserved, but reviewers/CI see a
# single commit instead of the full rebuild + merge history.
#
# WHEN: run AFTER modular is pushed green. The pre-push gate calls this in-loop
# right after the modular push. Uses `git commit-tree` so NO pre-commit hooks
# run and the tree is preserved byte-for-byte.
set -euo pipefail
REPO="${1:-/home/memento/PycharmProjects/Hummingbot/hummingbot}"
cd "$REPO"
git fetch origin --quiet
TREE=$(git rev-parse origin/modular^{tree})
PARENT=$(git rev-parse origin/ci-base)
MSG="modular snapshot for PR review ($(date +%Y-%m-%d)): squashed single-commit view of the ci-base->modular delta (sub-package wiring). CI state preserved so the PR surfaces gate failures. Regenerated each rebuild; not a hand-merge target."
COMMIT=$(git commit-tree "$TREE" -p "$PARENT" -S -m "$MSG")
git push -f origin "${COMMIT}:refs/heads/modular-pr"
echo "modular-pr regenerated:"
echo "  commit:      $COMMIT"
echo "  tree:        $TREE  (== origin/modular)"
echo "  parent:      $PARENT  (origin/ci-base)"
echo "  PR:          open modular-pr -> ci-base on GitHub"
