# shellcheck shell=bash
# Helpers for the bash tests: asserts, throwaway copies of the tool and test certificates. Each test
# file sources this, defines functions named test_*, and ends with `run_tests`.

REPO_ROOT=$(dirname "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")")
TESTS_FAILED=0
TESTS_RUN=0
# Every temporary file of a test file lives under TEST_TMP and is removed when the test file ends.
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/shelly-certs-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
	printf '    FAIL: %s\n' "$*"
	TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_eq() {
	local expected=$1 actual=$2 what=${3:-value}
	[[ $expected == "$actual" ]] || fail "$what: expected [$expected], got [$actual]"
}

assert_contains() {
	local haystack=$1 needle=$2 what=${3:-output}
	[[ $haystack == *"$needle"* ]] || fail "$what does not contain [$needle]. Full text: [$haystack]"
}

assert_not_contains() {
	local haystack=$1 needle=$2 what=${3:-output}
	[[ $haystack != *"$needle"* ]] || fail "$what contains [$needle] but should not. Full text: [$haystack]"
}

# Creates a throwaway copy of the tool (bin/ and lib/ plus empty config, secrets and data folders)
# and prints its path. The copy proves the tool works from any folder and keeps tests away from
# the real config.
make_instance() {
	local dir
	dir=$(mktemp -d "$TEST_TMP/instance.XXXXXX")
	cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$dir/"
	mkdir -p "$dir/config/devices.d" "$dir/secrets" "$dir/data"
	chmod 700 "$dir/secrets"
	printf '%s\n' "$dir"
}

# Writes a valid global config into an instance. Extra KEY=VALUE lines are appended.
write_global_config() {
	local dir=$1
	shift
	{
		printf '%s\n' \
			'ACME_EMAIL=admin@example.com' \
			'ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory' \
			'DNS_PROVIDER=hetzner' \
			'DNS_ENV_FILE=secrets/dns.env' \
			'KEY_TYPE=ec256' \
			'RENEW_DAYS=30' \
			'REBOOT_TIMEOUT=120'
		[[ $# -gt 0 ]] && printf '%s\n' "$@"
	} >"$dir/config/shelly-certs.conf"
	printf 'HETZNER_API_TOKEN_FILE=secrets/hetzner.token\n' >"$dir/secrets/dns.env"
	printf 'not-a-real-token\n' >"$dir/secrets/hetzner.token"
	chmod 600 "$dir/secrets/dns.env" "$dir/secrets/hetzner.token"
}

# write_device DIR NAME LINE... writes config/devices.d/NAME.conf with the given lines.
write_device() {
	local dir=$1 name=$2
	shift 2
	printf '%s\n' "$@" >"$dir/config/devices.d/$name.conf"
}

# make_cert DIR NAME KEYTYPE DOMAIN... creates a self-signed cert DIR/NAME.crt and key DIR/NAME.key
# whose SANs are the given domains. KEYTYPE is ec or rsa.
make_cert() {
	local dir=$1 name=$2 keytype=$3
	shift 3
	local san="" d
	for d in "$@"; do san+="${san:+,}DNS:$d"; done
	local -a newkey=(-newkey ec -pkeyopt ec_paramgen_curve:P-256)
	[[ $keytype == rsa ]] && newkey=(-newkey rsa:2048)
	openssl req -x509 "${newkey[@]}" -nodes -days 30 -subj "/CN=$1" -addext "subjectAltName=$san" \
		-keyout "$dir/$name.key" -out "$dir/$name.crt" 2>/dev/null
}

run_tests() {
	local t
	for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
		local before=$TESTS_FAILED
		TESTS_RUN=$((TESTS_RUN + 1))
		"$t"
		if [[ $TESTS_FAILED -eq $before ]]; then
			printf '  ok   %s\n' "$t"
		else
			printf '  FAIL %s\n' "$t"
		fi
	done
	[[ $TESTS_FAILED -eq 0 ]]
}
