#!/usr/bin/env bash
# Offline tests for the `deploy` and `status` commands and the lock that keeps two runs apart.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

DIR=$(make_instance)
write_global_config "$DIR"
# 127.0.0.1 port 443 is closed on a normal dev machine, so these devices count as unreachable.
write_device "$DIR" withcert 'DOMAINS=a.example.com' 'ADDRESS=127.0.0.1'
write_device "$DIR" nocert 'DOMAINS=n.example.com' 'ADDRESS=127.0.0.1'
mkdir -p "$DIR/data/certificates"
make_cert "$DIR/data/certificates" a.example.com ec a.example.com
CLI="$DIR/bin/shelly-certs"

test_deploy_unknown_device() {
	local out
	out=$("$CLI" deploy nope 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "$DIR/config/devices.d/nope.conf: cannot read file"
}

test_deploy_needs_device_name() {
	local out
	out=$("$CLI" deploy 2>&1)
	assert_eq 2 "$?" "exit code"
	assert_contains "$out" "deploy needs exactly one device name"
}

test_deploy_without_local_cert() {
	local out
	out=$("$CLI" deploy nocert 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "nocert: ERROR: no local certificate $DIR/data/certificates/n.example.com.crt, run 'shelly-certs run --device nocert' first"
}

test_deploy_refuses_while_locked() {
	local out
	(
		exec 8>"$DIR/data/.lock"
		flock 8
		sleep 3
	) &
	sleep 0.5
	out=$("$CLI" deploy withcert 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "another shelly-certs process holds $DIR/data/.lock"
	wait
}

test_status_table() {
	local out expiry days
	expiry=$(date -u -d "$(openssl x509 -in "$DIR/data/certificates/a.example.com.crt" -noout -enddate | sed 's/notAfter=//')" +%Y-%m-%d)
	out=$("$CLI" status 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_contains "$out" "DEVICE"
	assert_contains "$out" "DEVICE_CERT"
	days=$(awk '$1 == "withcert" {print $4}' <<<"$out")
	[[ $days == 29 || $days == 30 ]] || fail "days left: got [$days]"
	assert_not_contains "$out" "ENABLED"
	assert_eq "withcert a.example.com $expiry unreachable" \
		"$(awk '$1 == "withcert" {print $1, $2, $3, $5}' <<<"$out")" "withcert row"
	assert_eq "nocert n.example.com - - unreachable" \
		"$(awk '$1 == "nocert" {print $1, $2, $3, $4, $5}' <<<"$out")" "nocert row"
}

# A REBOOT=manual device without HTTPS (like a device that never had a certificate) can't be
# reached over TLS until it reboots. The pending marker must still win over "unreachable".
test_status_pending_reboot_when_device_has_no_https() {
	local out fp
	fp=$(openssl x509 -in "$DIR/data/certificates/a.example.com.crt" -noout -fingerprint -sha256 | sed 's/.*=//')
	mkdir -p "$DIR/data/status"
	printf '%s\n' "$fp" >"$DIR/data/status/withcert.pending"
	out=$("$CLI" status 2>&1)
	rm "$DIR/data/status/withcert.pending"
	assert_eq "pending-reboot" "$(awk '$1 == "withcert" {print $5}' <<<"$out")" "withcert state"
}

run_tests
