#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[[ -f SKILL.md ]] || fail 'SKILL.md is missing'
python3 - <<'PY'
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit("FAIL: YAML validation requires Python 3 with PyYAML")

lines = Path("SKILL.md").read_text(encoding="utf-8").splitlines()
if not lines or lines[0] != "---":
    raise SystemExit("FAIL: SKILL.md must begin with YAML frontmatter")
try:
    end = lines.index("---", 1)
    metadata = yaml.safe_load("\n".join(lines[1:end]))
except (ValueError, yaml.YAMLError) as error:
    raise SystemExit(f"FAIL: Invalid SKILL.md frontmatter: {error}")

for key in ("name", "description"):
    value = metadata.get(key) if isinstance(metadata, dict) else None
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"FAIL: SKILL.md frontmatter requires a nonempty {key}")
PY

cli=./scripts/otb_skill.sh
[[ -x "$cli" ]] || fail "$cli is missing or is not executable"

output=$("$cli" --help 2>&1) || fail "--help failed: $output"
for command in create-db create-table grant start stop; do
    grep -Eq "(^|[^[:alnum:]_-])${command}([^[:alnum:]_-]|$)" <<< "$output" ||
        fail "--help is missing $command"
done

# Record attempted tool execution even if the CLI ignores its exit status.
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
export OTB_TEST_TOOL_LOG="$scratch/tool.log"
cat > "$scratch/unexpected-tool" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >> "$OTB_TEST_TOOL_LOG"
exit 99
STUB
chmod +x "$scratch/unexpected-tool"
for tool in psql createdb pg_ctl pgxc_ctl; do
    ln -s unexpected-tool "$scratch/$tool"
done
export PATH="$scratch:$PATH"

check_dry_run() {
    local expected=$1
    shift
    local output status=0
    output=$("$cli" --dry-run "$@" 2>&1) || status=$?
    [[ ! -s "$OTB_TEST_TOOL_LOG" ]] ||
        fail "--dry-run $1 invoked an external tool: $(cat "$OTB_TEST_TOOL_LOG")"
    [[ $status -eq 0 ]] || fail "--dry-run $1 exited $status: $output"
    grep -Eiq -- "$expected" <<< "$output" ||
        fail "--dry-run $1 expected $expected, got: $output"
}

# Positional arguments are DB, then table and column definitions or grant role.
check_dry_run 'CREATE[[:space:]]+DATABASE[[:space:]]+"?skill_test_db"?[[:space:]]*;' \
    create-db skill_test_db
check_dry_run 'CREATE[[:space:]]+TABLE[[:space:]]+"?skill_test_table"?[[:space:]]*\([[:space:]]*id[[:space:]]+INT(EGER)?[[:space:]]*\)[[:space:]]+DISTRIBUTE[[:space:]]+BY[[:space:]]+SHARD' \
    create-table skill_test_table 'id INT' shard
check_dry_run 'GRANT[[:space:]]+SELECT[[:space:]]+ON[[:space:]]+TABLE[[:space:]]+"?skill_test_table"?[[:space:]]+TO[[:space:]]+"?skill_test_role"?[[:space:]]*;' \
    grant SELECT skill_test_table skill_test_role
check_dry_run '(^|[[:space:]/])(pg_ctl|pgxc_ctl)[[:space:]].*\bstart\b' start
check_dry_run '(^|[[:space:]/])(pg_ctl|pgxc_ctl)[[:space:]].*\bstop\b' stop

if "$cli" __unknown_skill_command__ > /dev/null 2>&1; then
    fail 'unknown command exited successfully'
fi

printf 'All skill tests passed.\n'
