# signed-commit

Commit a working tree to a branch through GitHub's API, so GitHub signs the
commit server-side.

A `git commit` on a runner is unsigned unless a private key sits on the
runner, which is not a trade worth making to keep a state branch's history
verifiable. `createCommitOnBranch` builds the commit server-side and signs it,
so the commit lands **Verified** and no key ever leaves a person's machine.
The author is whoever the token is, normally `github-actions[bot]`, rather
than an identity invented in a workflow file.

## Usage

```yaml
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false

      # ... produce the tree ...

      - uses: pkghaus/signed-commit@v1
        with:
          workdir: .
          branch: master
          message: Regenerate the PNG cuts
          pathspec: png/
          token: ${{ github.token }}
```

`persist-credentials: false` is correct here and not a contradiction: the
checkout is only ever read, and the write goes over the API with a token
passed explicitly.

### Inputs

| Input | Required | Description |
|---|---|---|
| `workdir` | yes | Directory whose tree is committed. Must be a checkout of `branch`. |
| `branch` | yes | Branch to commit onto. It must already exist. |
| `message` | yes | Commit message headline. |
| `pathspec` | no | Pathspecs, one per line. Without any, the whole tree is committed. |
| `token` | yes | A token with `contents: write`. |

A pathspec limits the commit to part of the tree, so a stray file written
elsewhere during a build cannot ride along inside a commit that claims to be
something narrower. Without one the whole working tree is committed, which is
what a state branch wants.

The action exits successfully without committing when the staged diff is
empty, so a reproducible build that produces identical bytes is a no-op rather
than an empty commit.

### Outputs

| Output | Description |
|---|---|
| `sha` | The oid of the commit, or empty when nothing was committed. |

Use it to name the commit rather than resolving the branch again. GitHub can
still resolve a branch to its previous tip seconds after the mutation lands,
so a workflow dispatched on the branch NAME may check out the commit before
this one and act on the wrong tree:

```yaml
      - uses: pkghaus/signed-commit@v1
        id: commit
        with:
          workdir: .
          branch: master
          message: "..."
          token: ${{ github.token }}

      - run: gh workflow run release.yml -f sha="$SHA"
        env:
          SHA: ${{ steps.commit.outputs.sha }}
```

An empty `sha` means the tree held no changes, which is not the same as a
commit that failed: a failure exits non-zero and emits nothing at all.

### The token is required, with no default

A composite action does not inherit the caller's secrets, and an input default
that silently resolved to the wrong token would be worse than an argument you
have to supply.

## What the API demands, and why each one bites

**It cannot create a branch.** A branch needs a commit to point at, and this is
the thing that makes commits. `git push` can bootstrap a missing branch; this
cannot, and it fails loudly rather than guessing at contents. If a state branch
is ever deleted, recreate it deliberately.

**It takes explicit additions and deletions, not a tree.** The diff is computed
from `git diff --cached -z --no-renames --name-status HEAD`. Staging first is
what makes git decide the file set rather than a directory walk: a deletion
missed that way would leave the file on the branch forever, because the
mutation only ever adds what it is handed. `--no-renames` because the mutation
has no concept of one, and `-z` because git quotes unusual paths in its default
output and reading raw never unquotes them.

**`expectedHeadOid` is required.** The write is conditional on the branch not
having moved since checkout, which is the behaviour you want: a mismatch means
something genuinely unexpected happened and failing is correct.

**File contents go base64 in the request body**, so payload size is the
practical ceiling on what one commit can carry.

## Verifying

The action reads `signature.isValid` from the mutation response and fails the
job if GitHub reports the commit unsigned, so an unsigned commit cannot pass
silently. From outside:

```bash
gh api repos/OWNER/REPO/commits/<sha> --jq '.commit.verification'
```

Want `verified: true`. Note that `git log --format=%G?` reads `E` locally for
these commits rather than `G`, because the signing key is GitHub's web-flow
key and it is not in your keyring. `E` means "cannot check", not "unsigned";
`N` would be the alarming one.

## License

```
Copyright 2026 pkg.haus

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## Buy us a coffee?

If you feel like buying us a coffee (or a beer?), donations are welcome:

```
BTC : bc1qq04jnuqqavpccfptmddqjkg7cuspy3new4sxq9
DOGE: DRBkryyau5CMxpBzVmrBAjK6dVdMZSBsuS
ETH : 0x2238A11856428b72E80D70Be8666729497059d95
LTC : MQwXsBrArLRHQzwQZAjJPNrxGS1uNDDKX6
```
