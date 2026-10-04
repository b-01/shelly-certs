#!/usr/bin/env bash
# Offline tests for lib/shelly.sh: the upload request body, RPC response handling, auth handling and
# the checks deploy_device does before it touches the network.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

SC_ROOT=$(make_instance)
write_global_config "$SC_ROOT"
# shellcheck source=../../lib/common.sh
source "$SC_ROOT/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$SC_ROOT/lib/config.sh"
# shellcheck source=../../lib/certs.sh
source "$SC_ROOT/lib/certs.sh"
# shellcheck source=../../lib/shelly.sh
source "$SC_ROOT/lib/shelly.sh"
load_global_config

CERTS="$TEST_TMP/certs"
mkdir -p "$CERTS"
make_cert "$CERTS" a ec a.example.com b.example.com
make_cert "$CERTS" other ec other.example.com
cat "$CERTS/a.crt" "$CERTS/other.crt" >"$CERTS/chain.crt"

# Sets up DEV for a device with the given extra lines, without a password unless one is given.
use_device() {
	write_device "$SC_ROOT" dev 'DOMAINS=a.example.com b.example.com' 'ADDRESS=192.0.2.10' "$@"
	load_device dev
}

test_upload_body() {
	local body="$TEST_TMP/upload-body.json"
	build_upload_body Shelly.PutHTTPServerCert "$CERTS/chain.crt" "$body"
	assert_eq '{"id":1,"method":"Shelly.PutHTTPServerCert"}' "$(jq -c '{id, method}' "$body")"
	jq -j '.params.data' "$body" | cmp -s - "$CERTS/chain.crt" || fail "uploaded data differs from the file"
}

test_rpc_result_ok() {
	local out
	out=$(rpc_result Shelly.PutHTTPServerCert 200 '{"id":1,"src":"shellyplus1-abc","result":{"len":5}}')
	assert_eq 0 "$?" "exit code"
	assert_eq '{"len":5}' "$(jq -c . <<<"$out")"
}

test_rpc_result_error_object() {
	local out
	out=$(rpc_result Shelly.PutHTTPServerCert 200 '{"id":1,"error":{"code":-103,"message":"Invalid argument"}}' 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "Shelly.PutHTTPServerCert failed: error -103: Invalid argument"
}

test_rpc_result_auth_failure() {
	local out
	out=$(rpc_result Shelly.Reboot 401 '' 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "Shelly.Reboot failed: authentication failed (HTTP 401), check SHELLY_PASSWORD_FILE"
}

test_rpc_result_other_http_error() {
	local out
	out=$(rpc_result Shelly.Reboot 500 'Internal error' 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "Shelly.Reboot failed: HTTP 500: Internal error"
}

test_auth_config_escapes_quotes_and_backslashes() {
	local pw="$TEST_TMP/escape.password"
	printf '%s\n' 'pa"ss\word' >"$pw"
	use_device "SHELLY_PASSWORD_FILE=$pw"
	assert_eq 'user = "admin:pa\"ss\\word"' "$(shelly_auth_config)"
}

# A stand-in curl on PATH that records its arguments and stdin, and answers like a device.
install_recording_curl() {
	local bindir="$TEST_TMP/fakebin"
	mkdir -p "$bindir"
	cat >"$bindir/curl" <<-EOF
		#!/usr/bin/env bash
		printf '%s\n' "\$@" >"$TEST_TMP/curl.args"
		cat >"$TEST_TMP/curl.stdin"
		printf '{"id":1,"result":{"ok":true}}\n200'
	EOF
	chmod +x "$bindir/curl"
	printf '%s\n' "$bindir"
}

test_password_goes_to_curl_stdin_not_arguments() {
	local pw="$TEST_TMP/secret.password" bindir out
	printf 'TopSecret123\n' >"$pw"
	use_device "SHELLY_PASSWORD_FILE=$pw"
	bindir=$(install_recording_curl)
	out=$(PATH="$bindir:$PATH" SHELLY_BASE_URL="http://192.0.2.10" shelly_rpc Shelly.GetDeviceInfo '{}')
	assert_eq '{"ok":true}' "$(jq -c . <<<"$out")"
	assert_not_contains "$(cat "$TEST_TMP/curl.args")" "TopSecret123" "curl arguments"
	assert_contains "$(cat "$TEST_TMP/curl.args")" "--anyauth" "curl arguments"
	assert_contains "$(cat "$TEST_TMP/curl.stdin")" 'user = "admin:TopSecret123"' "curl stdin"
}

test_no_auth_without_password_file() {
	local bindir
	use_device
	bindir=$(install_recording_curl)
	PATH="$bindir:$PATH" SHELLY_BASE_URL="http://192.0.2.10" shelly_rpc Shelly.GetDeviceInfo '{}' >/dev/null
	assert_not_contains "$(cat "$TEST_TMP/curl.args")" "--anyauth" "curl arguments"
}

test_deploy_refuses_key_that_does_not_match() {
	local out
	use_device
	out=$(deploy_device "$CERTS/a.crt" "$CERTS/other.key" 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "key $CERTS/other.key does not belong to certificate $CERTS/a.crt"
}

test_deploy_refuses_cert_missing_a_domain() {
	local out
	write_device "$SC_ROOT" dev 'DOMAINS=a.example.com c.example.com' 'ADDRESS=192.0.2.10'
	load_device dev
	out=$(deploy_device "$CERTS/a.crt" "$CERTS/a.key" 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "certificate $CERTS/a.crt does not cover: c.example.com"
}

test_deploy_refuses_missing_files() {
	local out
	use_device
	out=$(deploy_device "$CERTS/nope.crt" "$CERTS/a.key" 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "certificate file $CERTS/nope.crt does not exist"
}

test_deploy_dry_run_lists_calls_without_network() {
	local out
	use_device
	out=$(DRY_RUN=1 deploy_device "$CERTS/chain.crt" "$CERTS/a.key" 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_contains "$out" "dry run: would call Shelly.PutHTTPServerCert with $CERTS/chain.crt"
	assert_contains "$out" "dry run: would call Shelly.PutHTTPServerKey with $CERTS/a.key"
	assert_contains "$out" "dry run: would call Shelly.Reboot and wait up to 120s for the new certificate"
}

test_deploy_dry_run_manual_reboot() {
	local out
	use_device 'REBOOT=manual'
	out=$(DRY_RUN=1 deploy_device "$CERTS/chain.crt" "$CERTS/a.key" 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_not_contains "$out" "Shelly.Reboot"
	assert_contains "$out" "dry run: REBOOT=manual, would not reboot"
}

run_tests
