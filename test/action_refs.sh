#!/bin/bash
# Fails if any `uses: owner/repo@ref` in the workflows names a ref that doesn't
# exist upstream. actionlint and zizmor don't resolve refs, and a job that only
# runs after merge (build.yml's publish) would otherwise break silently.
# Needs the gh CLI with a token (GH_TOKEN in CI).
set -u
fail=0
while read -r use; do
    repo=$(printf '%s' "${use%@*}" | cut -d/ -f1-2) # drop sub-paths like codeql-action/upload-sarif
    ref=${use#*@}
    if gh api "repos/$repo/git/ref/tags/$ref" --silent 2>/dev/null ||
        gh api "repos/$repo/branches/$ref" --silent 2>/dev/null; then
        echo "ok      $use"
    else
        echo "MISSING $use"
        fail=1
    fi
done < <(grep -hoE 'uses: [^ #]+@[^ #]+' .github/workflows/*.yml | sed 's/^uses: //' | sort -u)
exit $fail
