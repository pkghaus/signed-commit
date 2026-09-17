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
# One scratch root for the whole suite, exported as TMPDIR so every mktemp
# below lands inside it. Three of the six groups cleaned up after themselves
# and three did not, and a group exiting early leaked whatever its own
# trailing rm would have removed.
TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
TALLY="$(mktemp)"
trap 'rm -rf "$TMPROOT"' EXIT

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
EXPECTED_ASSERTIONS=13

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
prev=""
for a in "\$@"; do
  case "\$prev" in --data) cp "\${a#@}" "$work/payload.json" ;; esac
  prev="\$a"
done
echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"deadbeefdeadbeef","signature":{"isValid":true,"state":"VALID"}}}}}'
FAKE
    chmod +x "$work/bin/curl"

    PATH="$work/bin:$PATH" "$ROOT/commit-branch.sh" "$repo" archive "test" >/dev/null 2>&1

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
    PATH="$work/bin:$PATH" "$ROOT/commit-branch.sh" "$repo" master "cuts" png/ >/dev/null 2>&1

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
    out="$work/gh-output"; : > "$out"
    GITHUB_OUTPUT="$out" PATH="$work/bin:$PATH" \
        "$ROOT/commit-branch.sh" "$repo" archive "test" >/dev/null 2>&1
    if [ -f "$work/called" ]; then no "an unchanged tree must not call the API" "curl was called"
    else ok "an unchanged tree must not call the API"; fi
    # Empty rather than absent. A caller distinguishes "nothing to commit" from
    # "committed" by reading this; an absent key and an empty one look the same
    # to a workflow expression, but only one of them is written on purpose.
    eq "and it reports an empty sha rather than none" "sha=" "$(cat "$out")"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "an HTTP failure reports what GitHub said, not just curl's exit code"
(
    work="$(mktemp -d)"
    export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/apt

    repo="$work/repo"; mkdir -p "$repo"; cd "$repo"
    git init -q -b archive .
    printf 'one\n' > keep.txt
    git add -A
    git -c user.name=t -c user.email=t@example.invalid commit -qm base
    printf 'two\n' > keep.txt

    # curl as --fail-with-body behaves on an HTTP error: the body is written to
    # the output AND the exit status is non-zero. That combination loses the
    # message unless it is handled -- set -e takes the exit before anything
    # prints the body, and the trap then deletes the file.
    mkdir -p "$work/bin"
    cat > "$work/bin/curl" <<'FAKE'
#!/bin/sh
printf '{"message":"Bad credentials","documentation_url":"https://docs.github.com/graphql"}'
exit 22
FAKE
    chmod +x "$work/bin/curl"

    out="$(PATH="$work/bin:$PATH" "$ROOT/commit-branch.sh" "$repo" archive "test" 2>&1)" \
        && rc=0 || rc=$?

    eq "the run fails" "1" "${rc:-0}"
    case "$out" in
        *"Bad credentials"*) ok "GitHub's own message reaches the log" ;;
        *) no "GitHub's own message reaches the log" "got [$out]" ;;
    esac
    case "$out" in
        *FATAL*) ok "and it is labelled as the failure it is" ;;
        *) no "and it is labelled as the failure it is" "got [$out]" ;;
    esac

    exit $((fail > 0))
) || fail=$((fail + 1))

echo "the commit oid reaches the caller, which is how a dispatch names the right tree"
(
    work="$(mktemp -d)"
    export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/packages
    # A real oid from the incident this output exists to prevent: the ouch bump
    # whose release was dispatched against the branch NAME and resolved to the
    # tip before it.
    oid=0fe3b0a783f5ec2041b2b90299b4be61123b15fd

    repo="$work/repo"; mkdir -p "$repo"; cd "$repo"
    git init -q -b master .
    printf 'VERSION=0.8.2\n' > package.conf
    git add -A
    git -c user.name=t -c user.email=t@example.invalid commit -qm base
    printf 'VERSION=0.8.3\n' > package.conf

    mkdir -p "$work/bin"
    cat > "$work/bin/curl" <<FAKE
#!/bin/sh
echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"$oid","signature":{"isValid":true,"state":"VALID"}}}}}'
FAKE
    chmod +x "$work/bin/curl"

    out="$work/gh-output"; : > "$out"
    GITHUB_OUTPUT="$out" PATH="$work/bin:$PATH" \
        "$ROOT/commit-branch.sh" "$repo" master "bump" >/dev/null 2>&1

    # The FULL oid. The log line prints oid[:12] and emitting that instead
    # would be a tag pointing at nothing, so the length is the assertion.
    eq "the full oid is emitted, not the 12-character log form" \
       "sha=$oid" "$(cat "$out")"

    # Every local run and this whole suite has no GITHUB_OUTPUT. Appending to
    # an unset path would abort the script after the commit had already landed.
    PATH="$work/bin:$PATH" "$ROOT/commit-branch.sh" "$repo" master "bump" \
        >/dev/null 2>&1 && rc=0 || rc=$?
    eq "an unset GITHUB_OUTPUT is not a failure" "0" "${rc:-1}"

    exit $((fail > 0))
) || fail=$((fail + 1))

echo "a commit GitHub refused to sign emits no oid at all"
(
    work="$(mktemp -d)"
    export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/packages

    repo="$work/repo"; mkdir -p "$repo"; cd "$repo"
    git init -q -b master .
    printf 'one\n' > f.txt
    git add -A
    git -c user.name=t -c user.email=t@example.invalid commit -qm base
    printf 'two\n' > f.txt

    mkdir -p "$work/bin"
    cat > "$work/bin/curl" <<'FAKE'
#!/bin/sh
echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","signature":{"isValid":false,"state":"UNSIGNED"}}}}}'
FAKE
    chmod +x "$work/bin/curl"

    out="$work/gh-output"; : > "$out"
    GITHUB_OUTPUT="$out" PATH="$work/bin:$PATH" \
        "$ROOT/commit-branch.sh" "$repo" master "test" >/dev/null 2>&1 && rc=0 || rc=$?

    eq "the run fails" "1" "${rc:-0}"
    # The oid is printed after the signature check for exactly this reason: a
    # caller that tagged this would be naming an unsigned commit.
    eq "and nothing is handed to the caller" "" "$(cat "$out")"

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
