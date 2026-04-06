# hb-custom-git-setup

Custom git workflows, rebuild scripts, and branch tracking for hummingbot.

## Overview

Infrastructure scripts for managing hummingbot's bleeding-edge and accelerated branch workflows. Handles composable `_for_bleed/` branch configuration, automated rebuilds with pytest and cython transforms, and maintenance operations.

## Scripts

| Script | Purpose |
|--------|---------|
| `rebuild-accelerated.sh` | Rebuild accelerated branches with transforms |
| `hummingbot-branch-tracking.sh` | Bleeding-edge branch rebuild and tracking |
| `hummingbot-maintenance.sh` | Repository maintenance operations |
| `hummingbot-full-testsuite.sh` | Comprehensive test suite execution |
| `hummingbot-interface-check.sh` | Interface validation |
| `hummingbot-rebase-check.sh` | Git rebase verification |
| `common.sh` | Shared logging and utility functions |

## Configuration

Branch tracking is configured in `configs/branch-tracking.yaml`.

## License

Apache-2.0 — see [LICENSE](LICENSE)
