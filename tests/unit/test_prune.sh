#!/usr/bin/env bash
# Offline tests for `shelly-certs prune`.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

# Creates an instance with certificates for two devices and one domain no device uses, each with
# the four files lego writes. Sets DIR and CERTS.
setup_instance() {
	local name
	DIR=$(make_instance)
	write_global_config "$DIR"
	write_device "$DIR" used 'DOMAINS=used.example.com' 'ADDRESS=127.0.0.1'
	write_device "$DIR" other 'DOMAINS=other.example.com' 'ADDRESS=127.0.0.1'
	CERTS="$DIR/data/certificates"
	mkdir -p "$CERTS"
	for name in used.example.com other.example.com orphan.example.com; do
		make_cert "$CERTS" "$name" ec "$name"
		cp "$CERTS/$name.crt" "$CERTS/$name.issuer.crt"
		echo '{}' >"$CERTS/$name.json"
	done
}

test_prune_lists_without_deleting() {
	local out
	setup_instance
	out=$("$DIR/bin/shelly-certs" prune 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_contains "$out" "unused certificate: orphan.example.com (expires "
	assert_contains "$out" "1 unused certificate. Run 'shelly-certs prune --yes' to delete them"
	assert_not_contains "$out" "used.example.com"
	assert_not_contains "$out" "other.example.com"
	assert_not_contains "$out" ".issuer"
	[[ -f $CERTS/orphan.example.com.crt ]] || fail "certificate was deleted without --yes"
}

test_prune_yes_deletes_all_files_of_unused_certificate() {
	local out
	setup_instance
	out=$("$DIR/bin/shelly-certs" prune --yes 2>&1)
	assert_eq 0 "$?" "exit code"
	assert_contains "$out" "deleted orphan.example.com"
	assert_eq "" "$(find "$CERTS" -name 'orphan.*')" "files of the unused certificate"
	assert_eq 8 "$(find "$CERTS" -type f | wc -l)" "files left in certificates/"
	out=$("$DIR/bin/shelly-certs" prune 2>&1)
	assert_contains "$out" "no unused certificates"
}

test_prune_refuses_with_broken_device_config() {
	local out
	setup_instance
	write_device "$DIR" broken 'ADDRESS=127.0.0.1'
	out=$("$DIR/bin/shelly-certs" prune --yes 2>&1)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "missing required key DOMAINS"
	assert_contains "$out" "device configs have errors. Fix them first, so prune can't delete a certificate a device still uses"
	[[ -f $CERTS/orphan.example.com.crt ]] || fail "certificate was deleted despite config errors"
}

test_prune_unknown_option() {
	local out
	setup_instance
	out=$("$DIR/bin/shelly-certs" prune --force 2>&1)
	assert_eq 2 "$?" "exit code"
	assert_contains "$out" "prune: unknown option --force"
}

run_tests
