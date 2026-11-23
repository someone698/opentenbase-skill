# opentenbase-ops

An Agent Skill for OpenTenBase distributed database operations and AIOps. It covers cluster health, topology, database and table provisioning, roles and grants, log triage, and cluster lifecycle operations. [SKILL.md](SKILL.md) defines the agent workflow and its approval rules.

## Prerequisites

- An agent with shell access and network access to the intended OpenTenBase coordinator.
- `otb_aiops` on the agent runner's `PATH`. Run the repository smoke suite with `bash tests/test_skill.sh`. The current suite uses `create-table <database> <table> <cols>`, while the wrapper takes `create-table <table> <cols> [shard|replication]` and selects the database with `-d`. The suite fails at that call.

From an OpenTenBase source checkout containing `contrib/otb_aiops`, build with a C++17 compiler and the development files for OpenTenBase libpq and libcurl.

  ```bash
  make -C contrib/otb_aiops
  make -C contrib/otb_aiops install
  export PATH="$HOME/.local/bin:$PATH"
  ```

- `psql` for catalog queries and approved SQL. Use your existing management controller and log access for lifecycle operations and log queries.
- Bash and the bundled `scripts/otb_skill.sh`. The wrapper needs local log access for `logs` and `pg_ctl` for local server lifecycle operations.

## Install the skill

Set `OTB_SKILL_SRC` to the absolute path of this checkout. From the target project or agent workspace, choose a parent directory for the platform you use.

| Platform | Skill parent directory | Invoke in a new session |
| --- | --- | --- |
| Claude Code | `.claude/skills` in the project, or `"$HOME/.claude/skills"` | `/opentenbase-ops Check cluster health` |
| Codex | `.agents/skills` in the project, or `"$HOME/.agents/skills"` | `$opentenbase-ops Check cluster health` |
| OpenClaw | `skills` in the configured agent workspace | Ask “Use opentenbase-ops to check cluster health.” |

[Claude Code skills](https://code.claude.com/docs/en/skills) · [Codex skill installation](https://developers.openai.com/api/reference/cli) · [OpenClaw skills](https://docs.openclaw.ai/skills)

Set `SKILL_PARENT` to the chosen directory and run:

```bash
(
  set -eu
  skill_dir="${SKILL_PARENT:?Set SKILL_PARENT}/opentenbase-ops"
  mkdir -p "$skill_dir"
  cp "${OTB_SKILL_SRC:?Set OTB_SKILL_SRC}/SKILL.md" "$skill_dir/"
  cp -R "$OTB_SKILL_SRC/scripts" "$skill_dir/"
)
```

Start the agent in the target project or workspace. For OpenClaw, make the required tools available on the runner that executes shell commands, including inside the sandbox if enabled.

## Quick start

Ask the agent to run health and show node groups for a specific environment. An example prompt:

> Use opentenbase-ops to check the staging coordinator at staging-cn.example:5432, database postgres, as otb_monitor. Report unreachable nodes and list node groups. Use read-only diagnostics.

Or run the health check directly after setting `CN_HOST`, `CN_PORT`, `OTB_READ_USER`, and `OTB_DB` to your staging connection values:

```bash
otb_aiops -h "${CN_HOST:?}" -p "${CN_PORT:?}" -U "${OTB_READ_USER:?}" -d "${OTB_DB:?}" health --json
```

For a change, ask for a plan first. For example, “Preview creating a sharded events table in staging appdb. Show the distribution key and verification query.” The agent uses a documented `--dry-run` if available and waits for explicit confirmation before applying any change or stopping a cluster.

## Test commands

From the source checkout, check the installed CLI and wrapper without connecting to a database:

```bash
otb_aiops --version
otb_aiops --help
bash -n scripts/otb_skill.sh
bash scripts/otb_skill.sh --help
bash scripts/otb_skill.sh -d appdb --dry-run create-table public.events \
  'tenant_id bigint, event_id bigint' shard
```

Run the repository smoke suite with `bash tests/test_skill.sh`. The current suite uses `create-table <database> <table> <cols>`, while the wrapper takes `create-table <table> <cols> [shard|replication]` and selects the database with `-d`. The suite fails at that call.

From an OpenTenBase source checkout containing the AIOps tool, run its test target:

```bash
make -C contrib/otb_aiops test
```

For a staging smoke test, run the health command above and the two catalog queries in [SKILL.md](SKILL.md#nodes-and-node-groups). Compare the reported node inventory and group membership with the deployment configuration.

## Example outputs

The CLI version in the environment used to verify the command interface:

```text
otb_aiops 0.1.0
```

Illustrative agent summary from a health and topology check:

```text
Staging coordinator cn1 is reachable.
Catalog lists cn1, dn1, and dn2. Runtime checks reached cn1 and dn1.
dn2 timed out. Its replication status could not be verified.
Node group default_group contains dn1 and dn2.
```

Illustrative response to a shutdown preview:

```text
Target: staging cluster
Plan: stop all components with the configured controller in smart mode.
Impact: shutdown waits for existing sessions to disconnect.
Verification: check all components with the controller after shutdown.
Status: preview complete. No shutdown was issued.
```
