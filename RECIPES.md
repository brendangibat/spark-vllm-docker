# Changing a Spark vLLM recipe — the repeatable, git-controlled process

The recipe YAMLs in [`recipes/`](recipes/) are the **single source of truth** for
how each model is launched on the DGX Spark nodes. A node launches a model via
`run-recipe.sh <recipe>`, which reads `recipes/<recipe>.yaml`.

> **Never hand-edit a recipe on a node.** An on-node edit (`ssh spark3` + `sed`)
> silently drifts that node from git *and* from the other nodes. That drift is
> real and has happened: nodes have carried different recipe sets and different
> values for the same model. The steps below keep every node equal to git.

## 1. Edit the recipe in a checkout of this repo, commit + push

```bash
$EDITOR recipes/<name>.yaml
git add recipes/<name>.yaml
git commit -m "recipe(<name>): <what changed and why>"
git push
```

## 2. Deploy the recipe to the affected node(s)

From the checkout — dry-run first (shows the exact diff), then apply:

```bash
./sync-recipes.sh spark3 spark4           # DRY-RUN (shows the diff)
./sync-recipes.sh --apply spark3 spark4   # sync (additive: adds/updates, never deletes)
./sync-recipes.sh --apply --prune spark3  # sync AND remove on-node recipes not in git
```

`sync-recipes.sh` rsyncs `recipes/` plus the launch scripts (`run-recipe.*`,
`launch-cluster.sh`, `autodiscover.sh`). It is **additive by default** (adds and
updates, never deletes); pass `--prune` to also delete on-node recipes not in git
(node == git exactly) — do that only after capturing any wanted on-node variants
into the repo. It is **safe to run while a model is serving** — `run-recipe.sh`
reads the recipe only at (re)launch time, so the running container is untouched
until you relaunch.

This is the recipe-FILE analogue of `build-and-copy.sh` (which copies the Docker
*image* to nodes). The sparks are not git checkouts (no repo credentials on the
nodes), so we push from one authenticated checkout rather than pulling per-node.

## 3. Relaunch the model to apply the change

A recipe change takes effect only on the **next launch**. To find the exact
launch parameters a running model uses, read them off the live process — the
flags are the ground truth, do not guess from a filename:

```bash
ssh <node> 'ps -eo args | grep -m1 "[v]llm serve"'
```

### Example: the DeepSeek-V4-Flash TP=2 pair (spark3 + spark4)

```bash
ssh spark3
cd ~/spark-vllm-docker
# Stop the running pair first to free unified memory, then relaunch:
./run-recipe.sh deepseek-v4-flash --ray \
  -n 192.168.100.13,192.168.100.14 \
  --eth-if enP2p1s0f0np0 --ib-if roceP2p1s0f0 \
  --gpu-mem 0.78 --max-model-len 262144
```

Confirm the change landed by reading the live cmdline (not the file):

```bash
ssh spark3 'ps -eo args | grep -m1 "[v]llm serve" \
  | tr " " "\n" | grep -A1 max-num-batched-tokens'
```

> On unified-memory GB10 nodes, watch host memory during relaunch — an over-large
> `--gpu-mem` / `--max-model-len` can wedge the kernel I/O subsystem (physical
> reboot required). See the operator's host-node-protection notes.

## Which nodes run which recipe

| Recipe | Node(s) | LiteLLM alias(es) |
|---|---|---|
| `deepseek-v4-flash` | spark3 + spark4 (TP=2 pair, ray over QSFP) | `cluster-planner`, `cluster-architect-lemma`, `cluster-architect-blueprint` |

(Extend this table as recipes are pinned to nodes. spark1/spark2 currently serve
their models via in-cluster k8s vLLM, not via these docker recipes.)

## Why not `git pull` on the node?

The sparks have no gitea/GitHub credentials, so a per-node `git pull` would
require distributing repo credentials to every node. `sync-recipes.sh` keeps
credentials on one authenticated checkout and pushes the tracked files out —
simpler to secure and identical in effect (the node ends up matching git).
