#!/usr/bin/env bash
# Offline tests for the certificate helpers in lib/certs.sh.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

SC_ROOT=$(make_instance)
# shellcheck source=../../lib/common.sh
source "$SC_ROOT/lib/common.sh"
# shellcheck source=../../lib/certs.sh
source "$SC_ROOT/lib/certs.sh"

CERTS="$TEST_TMP/certs"
mkdir -p "$CERTS"
make_cert "$CERTS" a ec a.example.com b.example.com
make_cert "$CERTS" other ec a.example.com
make_cert "$CERTS" rsa rsa rsa.example.com

test_cert_paths_follow_lego_layout() {
	assert_eq "$SC_ROOT/data/certificates/a.example.com.crt" "$(cert_path a.example.com)"
	assert_eq "$SC_ROOT/data/certificates/a.example.com.key" "$(key_path a.example.com)"
}

test_fingerprint_is_sha256_of_first_cert_in_bundle() {
	local expected
	expected=$(openssl x509 -in "$CERTS/a.crt" -noout -fingerprint -sha256 | sed 's/.*=//')
	cat "$CERTS/a.crt" "$CERTS/other.crt" >"$TEST_TMP/bundle.crt"
	assert_eq "$expected" "$(cert_fingerprint "$TEST_TMP/bundle.crt")"
}

test_fingerprint_of_missing_file_fails() {
	cert_fingerprint "$TEST_TMP/nope.crt" 2>/dev/null && fail "expected failure"
	return 0
}

test_key_match() {
	cert_key_match "$CERTS/a.crt" "$CERTS/a.key" || fail "matching EC pair reported as mismatch"
	cert_key_match "$CERTS/rsa.crt" "$CERTS/rsa.key" || fail "matching RSA pair reported as mismatch"
	cert_key_match "$CERTS/a.crt" "$CERTS/other.key" && fail "different keys reported as match"
	return 0
}

test_missing_domains() {
	local out
	out=$(cert_missing_domains "$CERTS/a.crt" a.example.com b.example.com)
	assert_eq 0 "$?" "exit code when all covered"
	assert_eq "" "$out"
	out=$(cert_missing_domains "$CERTS/a.crt" a.example.com c.example.com)
	assert_eq 1 "$?" "exit code when one is missing"
	assert_eq "c.example.com" "$out"
}

test_days_left() {
	local days
	days=$(cert_days_left "$CERTS/a.crt")
	[[ $days == 29 || $days == 30 ]] || fail "expected 29 or 30 days left, got $days"
}

test_expiry_date() {
	local expected
	expected=$(date -u -d "$(openssl x509 -in "$CERTS/a.crt" -noout -enddate | sed 's/notAfter=//')" +%Y-%m-%d)
	assert_eq "$expected" "$(cert_expiry_date "$CERTS/a.crt")"
}

test_served_fingerprint_from_tls_server() {
	local port pid out expected
	port=$((20000 + RANDOM % 20000))
	openssl s_server -accept "127.0.0.1:$port" -cert "$CERTS/a.crt" -key "$CERTS/a.key" -quiet \
		</dev/null >/dev/null 2>&1 &
	pid=$!
	sleep 0.5
	out=$(served_fingerprint 127.0.0.1 a.example.com "$port")
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	expected=$(cert_fingerprint "$CERTS/a.crt")
	[[ -n $expected ]] || fail "local fingerprint is empty"
	assert_eq "$expected" "$out"
}

test_served_fingerprint_fails_when_nothing_listens() {
	served_fingerprint 127.0.0.1 a.example.com 1 >/dev/null 2>&1 && fail "expected failure"
	return 0
}

run_tests
