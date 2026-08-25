#!/usr/bin/env bash
#
# action.yml carries shell in a `run:` block, which is real code that no
# ordinary linter sees: shellcheck reads .sh files and actionlint reads
# workflows, not action metadata. This extracts the body and lints it, and
# parses the file with a loader that rejects duplicate keys -- GitHub's parser
# rejects them and fails the action at load, while PyYAML's safe_load silently
# keeps the last one.
#
#   tests/lint-action.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

python3 - "$body" <<'PY'
import sys, yaml

class Strict(yaml.SafeLoader):
    pass

def no_dupes(loader, node, deep=False):
    seen = set()
    for k, _ in node.value:
        key = loader.construct_object(k, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key {key!r}", k.start_mark)
        seen.add(key)
    return yaml.constructor.SafeConstructor.construct_mapping(loader, node, deep)

Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dupes)

with open("action.yml") as fh:
    doc = yaml.load(fh, Strict)

assert doc["runs"]["using"] == "composite", "not a composite action any more"
steps = doc["runs"]["steps"]
assert len(steps) == 1, f"expected one step, found {len(steps)}"
step = steps[0]
assert step["shell"] == "bash", "run: without shell: bash is a load-time error"

# Every input the action declares must reach the step, or it is dead surface.
# Compared on the env VALUES, not the names: an input is free to arrive under
# a different variable (token -> GITHUB_TOKEN), so matching names would report
# a gap that is not there.
declared = set(doc["inputs"])
piped = " ".join(str(v) for v in step.get("env", {}).values())
missing = {name for name in declared if f"inputs.{name}" not in piped}
assert not missing, f"inputs never passed to the step: {sorted(missing)}"

# Expressions belong in env:, never in the run body, so a value containing
# shell metacharacters cannot become shell.
assert "${{" not in step["run"], "expression interpolated inside run:"

with open(sys.argv[1], "w") as out:
    out.write("#!/usr/bin/env bash\nset -euo pipefail\n")
    out.write(step["run"])
print("  ok   action.yml parses, one bash step, every input piped, no inline expressions")
PY

# SC2154: the variables come from the step's env:, which shellcheck cannot see.
shellcheck -S style -e SC2154 "$body"
echo "  ok   the run body is shellcheck-clean"
