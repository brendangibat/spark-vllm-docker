#!/bin/bash
# sync-recipes.sh — deploy git-controlled recipes + launch scripts to spark node(s).
#
# The recipe YAMLs in recipes/ are the SINGLE SOURCE OF TRUTH for how each model
# is launched on the DGX Spark nodes. A node launches a model via
#   run-recipe.sh <recipe>   (reads recipes/<recipe>.yaml)
# so the recipe files must live on the node. NEVER hand-edit a recipe on a node
# (it silently drifts the node from git AND from the other nodes). Instead, edit
# the recipe in a checkout of THIS repo, commit + push, then run this script to
# push the repo state to the affected node(s). Full runbook: RECIPES.md.
#
# This is the recipe-FILE analogue of build-and-copy.sh (which copies the Docker
# IMAGE to nodes). The nodes are not git checkouts (no repo credentials on the
# sparks), so we push from one authenticated checkout instead of pulling per-node.
#
# Usage:
#   ./sync-recipes.sh spark3 spark4            # DRY-RUN (shows exactly what would change)
#   ./sync-recipes.sh --apply spark3 spark4    # actually sync (additive, safe)
#   ./sync-recipes.sh --apply --prune spark3   # sync AND delete on-node recipes not in git
#   ./sync-recipes.sh --apply                  # autodiscover peers (COPY_HOSTS in .env)
#
# Safe to run while a model is serving: run-recipe.sh reads the recipe only at
# (re)launch time, so the running container is untouched until you relaunch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${SPARK_VLLM_DIR:-spark-vllm-docker}"   # relative to the remote $HOME
SSH_USER="${SSH_USER:-$USER}"
APPLY=false
PRUNE=false
HOSTS=()

for a in "$@"; do
  case "$a" in
    --apply) APPLY=true ;;
    --prune) PRUNE=true ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) HOSTS+=("$a") ;;
  esac
done

# Autodiscover node list from .env COPY_HOSTS when none given.
if [ "${#HOSTS[@]}" -eq 0 ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/autodiscover.sh" 2>/dev/null || true
  if [ -n "${DOTENV_COPY_HOSTS:-}" ]; then IFS=',' read -ra HOSTS <<< "$DOTENV_COPY_HOSTS"; fi
fi
if [ "${#HOSTS[@]}" -eq 0 ]; then
  echo "error: no nodes given. Pass node names, or set COPY_HOSTS in .env." >&2
  exit 2
fi

# Warn (don't block) if the checkout has uncommitted recipe changes — you'd be
# deploying un-versioned state, the exact drift this script exists to prevent.
if command -v git >/dev/null && git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if ! git -C "$SCRIPT_DIR" diff --quiet -- recipes 2>/dev/null; then
    echo "WARNING: recipes/ has uncommitted changes in this checkout — commit + push first" >&2
  fi
fi

# Launch scripts are copied additively. recipes/ is ADDITIVE by default (safe);
# pass --prune to add --delete so the node EXACTLY matches git (removes on-node
# recipes not in git) — do that only after capturing wanted node variants into git.
SCRIPTS=(run-recipe.py run-recipe.sh launch-cluster.sh autodiscover.sh)
MODE=$([ "$APPLY" = true ] && echo APPLY || echo DRY-RUN)
rc=0
for h in "${HOSTS[@]}"; do
  echo "=== ${h} (${MODE}$([ "$PRUNE" = true ] && echo ', PRUNE')) ==="
  common=(-az)
  [ "$APPLY" = true ] || common+=(--dry-run --itemize-changes)
  recipe_opts=("${common[@]}")
  [ "$PRUNE" = true ] && recipe_opts+=(--delete)
  ( cd "$SCRIPT_DIR" \
      && rsync "${recipe_opts[@]}" recipes/ "${SSH_USER}@${h}:${DEST}/recipes/" \
      && rsync "${common[@]}" "${SCRIPTS[@]}" "${SSH_USER}@${h}:${DEST}/" ) || rc=$?
done

if [ "$APPLY" = true ]; then
  echo "Synced. A recipe change takes effect only on the next launch — relaunch the"
  echo "affected model (see RECIPES.md 'Relaunch the model to apply')."
else
  echo "DRY-RUN only. Re-run with --apply to sync."
fi
exit "$rc"
