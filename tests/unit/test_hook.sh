#!/usr/bin/env bash
# Offline tests for bin/shelly-deploy-hook: finding the device, the env allowlist and the status file.
# The deploys here fail on purpose before reaching a device: either cert and key don't match, or a
# stand-in curl answers like an unreachable device.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

DIR=$(make_instance)
write_global_config "$DIR"
write_device "$DIR" dev 'DOMAINS=a.example.com' 'ADDRESS=192.0.2.10'
CERTS="$TEST_TMP/certs"
mkdir -p "$CERTS"
make_cert "$CERTS" a ec a.example.com
make_cert "$CERTS" other ec other.example.com
HOOK="$DIR/bin/shelly-deploy-hook"

test_hook_needs_lego_variables() {
	local out
	out=$(env -u LEGO_HOOK_CERT_PATH "$HOOK" 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "LEGO_HOOK_CERT_PATH and LEGO_HOOK_CERT_KEY_PATH must be set; lego sets them when it calls this hook"
}

test_hook_unknown_domain() {
	local out
	out=$(LEGO_HOOK_CERT_PATH="$CERTS/a.crt" LEGO_HOOK_CERT_KEY_PATH="$CERTS/a.key" \
		LEGO_HOOK_CERT_NAME=zzz.example.com LEGO_HOOK_CERT_DOMAINS=zzz.example.com "$HOOK" 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "no device config has zzz.example.com as first domain"
}

test_hook_finds_device_by_domain_and_writes_failed_status() {
	local out
	rm -f "$DIR/data/status/dev.hook"
	out=$(LEGO_HOOK_CERT_PATH="$CERTS/a.crt" LEGO_HOOK_CERT_KEY_PATH="$CERTS/other.key" \
		LEGO_HOOK_CERT_NAME=a.example.com LEGO_HOOK_CERT_DOMAINS=a.example.com "$HOOK" 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "dev: ERROR: key $CERTS/other.key does not belong to certificate $CERTS/a.crt"
	assert_eq "failed $(openssl x509 -in "$CERTS/a.crt" -noout -fingerprint -sha256 | sed 's/.*=//')" \
		"$(cat "$DIR/data/status/dev.hook")" "status file"
}

test_hook_uses_device_from_env_variable() {
	local out
	write_device "$DIR" second 'DOMAINS=second.example.com' 'ADDRESS=192.0.2.11'
	out=$(SHELLY_CERTS_DEVICE=second LEGO_HOOK_CERT_PATH="$CERTS/a.crt" LEGO_HOOK_CERT_KEY_PATH="$CERTS/other.key" \
		LEGO_HOOK_CERT_NAME=a.example.com "$HOOK" 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "second: ERROR: key"
	rm "$DIR/config/devices.d/second.conf"
}

test_hook_env_allowlist() {
	local out
	out=$(
		# shellcheck disable=SC2016 # $SC_ROOT is meant for the inner bash
		env -i PATH="$PATH" HOME="$TEST_TMP" LANG=C.UTF-8 HETZNER_API_TOKEN=leak HETZNER_API_TOKEN_FILE=/x \
			LEGO_HOOK_CERT_PATH=/c LEGO_HOOK_CERT_KEY_PATH=/k SHELLY_CERTS_DEVICE=dev SOME_OTHER=1 \
			bash -c 'SC_ROOT='"$DIR"'; source "$SC_ROOT/lib/common.sh"; hook_env_keep_names'
	)
	assert_eq $'HOME\nLANG\nLEGO_HOOK_CERT_KEY_PATH\nLEGO_HOOK_CERT_PATH\nPATH\nSHELLY_CERTS_DEVICE' "$out"
}

test_hook_children_never_see_dns_token() {
	local bindir="$TEST_TMP/fakebin" out
	mkdir -p "$bindir"
	# Stand-in curl that records its environment and fails like an unreachable device.
	printf '#!/usr/bin/env bash\nenv >"%s"\nexit 7\n' "$TEST_TMP/curl.env" >"$bindir/curl"
	chmod +x "$bindir/curl"
	out=$(PATH="$bindir:$PATH" HETZNER_API_TOKEN=leak-me SHELLY_CERTS_DEVICE=dev \
		LEGO_HOOK_CERT_PATH="$CERTS/a.crt" LEGO_HOOK_CERT_KEY_PATH="$CERTS/a.key" "$HOOK" 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "dev: ERROR: device does not answer at 192.0.2.10"
	[[ -s $TEST_TMP/curl.env ]] || fail "curl was not called"
	assert_contains "$(cat "$TEST_TMP/curl.env")" "SHELLY_CERTS_DEVICE=dev" "curl environment"
	assert_not_contains "$(cat "$TEST_TMP/curl.env")" "leak-me" "curl environment"
}

run_tests
