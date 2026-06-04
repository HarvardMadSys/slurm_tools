# Environment variables

All variables are optional. Most have defaults that target a Harvard FASRC-style cluster;
override them in your shell rc or via `export` before running any tool.

---

## Usage tracking

### `SLURM_TOOLS_USAGE_LOG`

**Used by:** every `st` invocation

Path to the shared usage log. Each invocation appends one tab-separated record
containing a UTC timestamp, resolved username, hostname, shell-escaped working
directory, `st` version, Slurm job ID (`-` when unset), and shell-escaped
command.

```bash
export SLURM_TOOLS_USAGE_LOG="/scratch/st/usage_$(hostname).log"
```

Default: `/scratch/st/usage_$(hostname).log`

The parent directory and file are created on a best-effort basis with modes
`1777` and `0666`, respectively. Pre-create them with tighter group permissions
or ACLs when required. Logging failures never prevent `st` from running.
The log contains full command arguments and is intended for usage tracking, not
tamper-resistant auditing.

---

## Site configuration

### `SLURM_TOOLS_ALLOC_SCRIPT`

**Used by:** `st alloc`

Path to the batch script submitted as the placeholder "hold" job. The script should
run indefinitely (e.g. `sleep infinity`) so the allocation stays alive while you work.

```bash
export SLURM_TOOLS_ALLOC_SCRIPT=/path/to/sleep.sh
```

Default: a Harvard lab-specific path (`/n/holylabs/.../sleep.sh`). **Must be set on
any other cluster.**

---

### `SLURM_TOOLS_DEFAULT_PARTITION`

**Used by:** `st nodes`

Default value for `-p PARTITION` when the flag is omitted.

```bash
export SLURM_TOOLS_DEFAULT_PARTITION=gpu
```

Default: `gpu_requeue`

---

### `SLURM_TOOLS_MIG_PARTITION`

**Used by:** `st alloc`, `st submit`

When `-G a100mig` is combined with `-p best`, this partition is used directly instead
of calling `st partition` (because MIG slices have non-standard GRES names that
confuse the recommendation logic).

```bash
export SLURM_TOOLS_MIG_PARTITION=gpu_mig
```

Default: `gpu_test`

---

### `SLURM_TOOLS_SKIP_PARTITIONS_GPU_JOB`

**Used by:** `st partition`

Space-separated list of partition names to exclude from recommendations when the job
requests at least one GPU. Useful for CPU-only or shared partitions that technically
allow GPU jobs but are a poor choice.

```bash
export SLURM_TOOLS_SKIP_PARTITIONS_GPU_JOB="serial_requeue shared"
```

Default: `serial_requeue`

---

### `SLURM_TOOLS_SKIP_PARTITIONS_CPU_JOB`

**Used by:** `st partition`

Same as above but applied when the job requests zero GPUs (`-g 0`). Typically used
to hide GPU-only partitions from CPU job recommendations.

```bash
export SLURM_TOOLS_SKIP_PARTITIONS_CPU_JOB="gpu_requeue gpu_test gpu"
```

Default: `gpu_requeue gpu_test`

---

## Upgrade control

### `SLURM_TOOLS_SKIP_UPGRADE`

**Used by:** `st alloc`, `st submit`

Set to `1` to disable the automatic daily version check entirely. Useful in scripts,
batch jobs, or offline environments.

```bash
export SLURM_TOOLS_SKIP_UPGRADE=1
```

Default: unset (upgrade check enabled)

---

### `SLURM_TOOLS_FORCE_UPGRADE_CHECK`

**Used by:** `st alloc`, `st submit`

Set to `1` to force a version check on every invocation, bypassing the 24-hour
cooldown cache (`~/.cache/slurm_tools/last_version_check`).

```bash
SLURM_TOOLS_FORCE_UPGRADE_CHECK=1 st alloc -g 1
```

Default: unset

---

## Upgrade script

These three are read by `upgrade.sh` / `st upgrade` and can also be set
before calling `st alloc` or `st submit` (which invoke the upgrade script
internally).

### `SLURM_TOOLS_ROOT`

Override the install directory. Normally resolved automatically from the symlinks in
`~/.local/bin`. Set this when running `upgrade.sh` directly from a non-standard path.

```bash
SLURM_TOOLS_ROOT=~/my_slurm_tools bash upgrade.sh -y
```

---

### `SLURM_TOOLS_REPO`

GitHub `owner/repo` to pull releases from.

```bash
export SLURM_TOOLS_REPO=myorg/slurm_tools
```

Default: `HarvardMadSys/slurm_tools`

---

### `SLURM_TOOLS_BRANCH`

Git branch to track for upgrades.

```bash
export SLURM_TOOLS_BRANCH=dev
```

Default: `main`

---

## Minimal non-Harvard setup

Only `SLURM_TOOLS_ALLOC_SCRIPT` is strictly required on another cluster:

```bash
export SLURM_TOOLS_ALLOC_SCRIPT=/usr/local/share/scripts/sleep.sh
export SLURM_TOOLS_DEFAULT_PARTITION=gpu
export SLURM_TOOLS_SKIP_PARTITIONS_CPU_JOB="gpu"
```
