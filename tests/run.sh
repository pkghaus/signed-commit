#!/usr/bin/env bash
#
# What commit-branch.sh must never get wrong, since every failure here is
# silent: a commit that claims to describe a tree but omits a deletion leaves
# that file on the branch forever, and a commit scoped to a pathspec that
# leaks is a build step's stray output landing in a signed commit.
#
#   tests/run.sh
#
# No network: curl is replaced on PATH, so the payload is inspected rather
# than posted.

# Two habits of this file that shellcheck reads as mistakes, both deliberate.
# Each group runs in a subshell so its environment cannot leak into the next,
# hence the subshell-local assignment warnings.
# shellcheck disable=SC2030,SC2031

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

# Each group runs in a subshell, so a counter variable incremented inside one
# never reaches this scope. The tally goes through a file instead, which is
# the only way the assertion-count guard below can see anything at all.
TALLY="$(mktemp)"
trap 'rm -f "$TALLY"' EXIT

ok() { printf '  ok   %s\n' "$1"; echo ok >> "$TALLY"; }
no() { printf '  FAIL %s\n    %s\n' "$1" "$2"; echo no >> "$TALLY"; fail=$((fail + 1)); }

eq() { # label expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$3] want [$2]"; fi
}

# Every assertion this file is supposed to make. Groups run in subshells and
# the harness does not use `set -e`, so a helper that goes missing makes its
# assertions vanish rather than fail -- which is exactly what happened when
# these groups were first lifted out of pkghaus/apt: eq() was left behind and
# the suite still printed "all tests passed". Bump this when adding one.
EXPECTED_ASSERTIONS=5

echo "the signed-commit payload describes every change, deletions included"
(
    work="$(mktemp -d)"
    export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/apt

    # A branch with three files, committed, then one of each kind of change.
    repo="$work/repo"; mkdir -p "$repo"; cd "$repo"
    git init -q -b archive .
    printf 'one\n' > keep.txt; printf 'two\n' > change.txt; printf 'three\n' > gone.txt
    git add -A
    git -c user.name=t -c user.email=t@example.invalid commit -qm base
    printf 'changed\n' > change.txt
    rm gone.txt
    printf 'new\n' > added.txt

    # A curl that captures the payload instead of sending it, and answers with
    # what a successful mutation looks like.
    mkdir -p "$work/bin"
    cat > "$work/bin/curl" <<FAKE
#!/bin/sh
for a in "\$@"; do case "\$a" in --data@*) ;; esac; done
prev=""
for a in "\$@"; do
  case "\$prev" in --data) cp "\${a#@}" "$work/payload.json" ;; esac
  prev="\$a"
done
echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"deadbeefdeadbeef","signature":{"isValid":true,"state":"VALID"}}}}}'
FAKE
    chmod +x "$work/bin/curl"

    PATH="$work/bin:$PATH" "$ROOT/commit-branch.sh" "$repo" archive "test" >/dev/null 2>&1 || true

    if [ ! -f "$work/payload.json" ]; then
        no "the payload is built" "no payload captured"
    else
        adds=$(python3 -c "import json;d=json.load(open('$work/payload.json'));print(' '.join(sorted(a['path'] for a in d['variables']['input']['fileChanges']['additions'])))")
        dels=$(python3 -c "import json;d=json.load(open('$work/payload.json'));print(' '.join(sorted(x['path'] for x in d['variables']['input']['fileChanges']['deletions'])))")
        eq "additions are the new and changed files only" "added.txt change.txt" "$adds"
        eq "the deleted file is listed as a deletion"     "gone.txt"            "$dels"
        body=$(python3 -c "
import json,base64
d=json.load(open('$work/payload.json'))
a={x['path']: base64.b64decode(x['contents']).decode() for x in d['variables']['input']['fileChanges']['additions']}
print(a['change.txt'].strip())")
        eq "the addition carries the NEW contents" "changed" "$body"
    fi
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "a pathspec keeps everything outside it out of the commit"
(
    work="$(mktemp -d)"; export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/brand
    repo="$work/repo"; mkdir -p "$repo/png" "$repo/src"; cd "$repo"
    git init -q -b master .
    printf 'svg\n' > src/mark.svg; printf 'old\n' > png/mark-16.png
    git add -A; git -c user.name=t -c user.email=t@example.invalid commit -qm base
    # A build touches png/, and something strays outside it.
    printf 'new\n' > png/mark-16.png
    printf 'regenerated\n' > png/mark-32.png
    printf 'STRAY\n' > oops.txt
    printf 'edited\n' > src/mark.svg

    mkdir -p "$work/bin"
    cat > "$work/bin/curl" <<FAKE
#!/bin/sh
prev=""
for a in "\$@"; do
  case "\$prev" in --data) cp "\${a#@}" "$work/payload.json" ;; esac
  prev="\$a"
done
echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"cafebabecafebabe","signature":{"isValid":true,"state":"VALID"}}}}}'
FAKE
    chmod +x "$work/bin/curl"
    PATH="$work/bin:$PATH" "$ROOT/commit-branch.sh" "$repo" master "cuts" png/ >/dev/null 2>&1 || true

    if [ ! -f "$work/payload.json" ]; then
        no "a pathspec-scoped commit is built" "no payload captured"
    else
        paths=$(python3 -c "import json;d=json.load(open('$work/payload.json'));c=d['variables']['input']['fileChanges'];print(' '.join(sorted([a['path'] for a in c['additions']] + [x['path'] for x in c['deletions']])))")
        eq "only the pathspec is committed" "png/mark-16.png png/mark-32.png" "$paths"
    fi
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "a tree with no changes makes no commit"
(
    work="$(mktemp -d)"; export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/apt
    repo="$work/repo"; mkdir -p "$repo"; cd "$repo"
    git init -q -b archive .
    printf 'x\n' > f.txt; git add -A
    git -c user.name=t -c user.email=t@example.invalid commit -qm base
    mkdir -p "$work/bin"
    printf '#!/bin/sh\ntouch %s/called\n' "$work" > "$work/bin/curl"; chmod +x "$work/bin/curl"
    PATH="$work/bin:$PATH" "$ROOT/commit-branch.sh" "$repo" archive "test" >/dev/null 2>&1
    if [ -f "$work/called" ]; then no "an unchanged tree must not call the API" "curl was called"
    else ok "an unchanged tree must not call the API"; fi
    exit $((fail > 0))
) || fail=$((fail + 1))

echo
ran="$(wc -l < "$TALLY")"
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
    echo "FAIL: $ran assertions ran, expected $EXPECTED_ASSERTIONS."
    echo "      An assertion was skipped, not failed -- look for a missing"
    echo "      helper or a group that exited early."
    exit 1
fi
if [ "$fail" -eq 0 ]; then
    echo "all $ran assertions passed"
else
    echo "$fail failing test group(s)"
fi
exit $((fail > 0))
