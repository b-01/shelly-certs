#!/usr/bin/env bash
# Runs shellcheck over all bash files, then every offline unit test in tests/unit/.
# The staging tests (real Let's Encrypt staging and real devices) are separate:
# see tests/staging/run-staging-tests.sh.
set -uo pipefail

REPO_ROOT=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
failed=0

echo "shellcheck"
mapfile -t shell_files < <(
	cd "$REPO_ROOT" &&
		{
			find bin -type f
			find lib tests -type f -name '*.sh'
			find . -maxdepth 1 -type f -name '*.sh'
		} | sort
)
if (cd "$REPO_ROOT" && shellcheck "${shell_files[@]}"); then
	echo "  ok   ${#shell_files[@]} files"
else
	failed=1
fi

for test_file in "$REPO_ROOT"/tests/unit/test_*.sh; do
	basename "$test_file"
	bash "$test_file" || failed=1
done

if [[ $failed -ne 0 ]]; then
	echo "FAILED"
	exit 1
fi
echo "all passed"
