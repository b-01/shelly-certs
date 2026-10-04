#!/usr/bin/env bash
# Offline tests for `shelly-certs run`. A stand-in lego on PATH records each call and then acts the
# way the real lego and deploy hook would (new cert, hook status file, exit code), as told by
# $FAKE_LEGO_DIR/mode.<device>. A stand-in curl fails like an unreachable device, so drift deploys
# fail before any network access. Devices use 127.0.0.1, where port 443 is closed on a dev machine.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

FAKEBIN="$TEST_TMP/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/lego" <<'EOF'
#!/usr/bin/env bash
printf 'device=%s pwd=%s args=%s\n' "${SHELLY_CERTS_DEVICE:-}" "$PWD" "$*" >>"$FAKE_LEGO_DIR/calls"
path="" name="" san=""
while [[ $# -gt 0 ]]; do
	case $1 in
	--path) path=$2 && shift ;;
	--cert.name) name=$2 && shift ;;
	--domains) san+="${san:+,}DNS:$2" && shift ;;
	esac
	shift
done
if [[ -e $path/status/$SHELLY_CERTS_DEVICE.hook ]]; then
	echo "$SHELLY_CERTS_DEVICE" >>"$FAKE_LEGO_DIR/stale-status"
fi
new_cert() {
	mkdir -p "$path/certificates" "$path/status"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 90 -subj "/CN=$name" \
		-addext "subjectAltName=$san" -keyout "$path/certificates/$name.key" \
		-out "$path/certificates/$name.crt" 2>/dev/null
	fp=$(openssl x509 -in "$path/certificates/$name.crt" -noout -fingerprint -sha256)
	fp=${fp#*=}
}
echo "level=INFO msg=fake lego for $name"
mode=$(cat "$FAKE_LEGO_DIR/mode.$SHELLY_CERTS_DEVICE" 2>/dev/null || echo noop)
case $mode in
noop) exit 0 ;;
acme-fail)
	echo "level=ERROR msg=acme: error 400"
	exit 1
	;;
renew-ok)
	new_cert
	echo "$SHELLY_CERTS_DEVICE: line from the hook"
	echo "ok $fp" >"$path/status/$SHELLY_CERTS_DEVICE.hook"
	;;
renew-hook-failed)
	new_cert
	echo "failed $fp" >"$path/status/$SHELLY_CERTS_DEVICE.hook"
	exit 1
	;;
renew-no-status)
	new_cert
	exit 1
	;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 7\n' >"$FAKEBIN/curl"
chmod +x "$FAKEBIN/lego" "$FAKEBIN/curl"

# Creates an instance with a valid global config and a fresh FAKE_LEGO_DIR; sets DIR and LEGO_DIR.
setup_instance() {
	DIR=$(make_instance)
	write_global_config "$DIR"
	mkdir -p "$DIR/data/certificates"
	LEGO_DIR=$(mktemp -d "$TEST_TMP/lego.XXXXXX")
	touch "$LEGO_DIR/calls"
}

# add_device NAME MODE LINE... writes a device on 127.0.0.1 with domain NAME.example.com and sets
# what the stand-in lego does for it.
add_device() {
	local name=$1 mode=$2
	shift 2
	write_device "$DIR" "$name" "DOMAINS=$name.example.com" 'ADDRESS=127.0.0.1' "$@"
	printf '%s\n' "$mode" >"$LEGO_DIR/mode.$name"
}

fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//'; }

run_cli() {
	PATH="$FAKEBIN:$PATH" FAKE_LEGO_DIR="$LEGO_DIR" "$DIR/bin/shelly-certs" "$@" 2>&1
}

test_run_mixed_results_and_summary() {
	local out rc
	setup_instance
	add_device acmefail acme-fail
	add_device drift noop
	make_cert "$DIR/data/certificates" drift.example.com ec drift.example.com
	add_device fresh renew-ok
	add_device hookfail renew-hook-failed
	add_device nostatus renew-no-status
	make_cert "$DIR/data/certificates" nostatus.example.com ec nostatus.example.com
	mkdir -p "$DIR/data/status"
	# A status file from an earlier run must not count for this one.
	printf 'ok %s\n' "$(fingerprint "$DIR/data/certificates/nostatus.example.com.crt")" >"$DIR/data/status/nostatus.hook"

	out=$(run_cli run)
	rc=$?
	assert_eq 1 "$rc" "exit code"
	assert_contains "$out" "acmefail: ERROR: lego failed (exit code 1)"
	assert_contains "$out" "drift: no HTTPS answer from the device, deploying the local certificate"
	assert_contains "$out" "drift: ERROR: device does not answer at 127.0.0.1"
	assert_contains "$out" "hookfail: ERROR: lego saved a new certificate, but the deploy hook reports: failed"
	assert_contains "$out" "nostatus: ERROR: lego saved a new certificate, but the deploy hook reports: nothing"
	assert_contains "$out" "summary: 5 devices, 4 failed"
	assert_contains "$out" "  acmefail: FAILED: lego failed, no local certificate"
	assert_contains "$out" "  drift: FAILED: deploy failed"
	assert_contains "$out" "  fresh: new certificate deployed"
	assert_contains "$out" "  hookfail: FAILED: new certificate, deploy failed"
	assert_contains "$out" "  nostatus: FAILED: new certificate, deploy failed"
	assert_eq 5 "$(wc -l <"$LEGO_DIR/calls")" "number of lego calls"
	[[ ! -e $LEGO_DIR/stale-status ]] || fail "lego ran while an old status file existed for: $(cat "$LEGO_DIR/stale-status")"
}

test_run_unexpected_error_fails_only_that_device() {
	local out
	setup_instance
	add_device bad noop
	echo junk >"$DIR/data/certificates/bad.example.com.crt"
	add_device good renew-ok
	out=$(run_cli run)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "  bad: FAILED: unexpected error, see the log above"
	assert_contains "$out" "  good: new certificate deployed"
}

test_run_lego_environment_and_output() {
	local out
	setup_instance
	add_device fresh renew-ok
	out=$(run_cli run)
	assert_eq 0 "$?" "exit code"
	assert_contains "$(cat "$LEGO_DIR/calls")" "device=fresh pwd=$DIR args=--log.format text run --accept-tos"
	assert_contains "$out" "fresh: lego: level=INFO msg=fake lego for fresh.example.com"
	# Lines from the hook already carry the device name and are passed on unchanged.
	assert_contains "$out" $'\nfresh: line from the hook'
	assert_contains "$out" "summary: 1 device, 0 failed"
}

test_run_device_option() {
	local out
	setup_instance
	add_device one noop
	add_device two renew-ok 'REBOOT=manual'
	out=$(run_cli run --device two)
	assert_eq 0 "$?" "exit code"
	assert_contains "$out" "  two: new certificate uploaded, reboot pending"
	assert_not_contains "$out" "one:"
	assert_eq 1 "$(wc -l <"$LEGO_DIR/calls")" "number of lego calls"
}

test_run_pending_reboot_is_not_a_failure() {
	local out
	setup_instance
	add_device manual noop 'REBOOT=manual'
	make_cert "$DIR/data/certificates" manual.example.com ec manual.example.com
	mkdir -p "$DIR/data/status"
	fingerprint "$DIR/data/certificates/manual.example.com.crt" >"$DIR/data/status/manual.pending"
	out=$(run_cli run)
	assert_eq 0 "$?" "exit code"
	assert_contains "$out" "manual: the certificate is uploaded and waits for you to reboot the device"
	assert_contains "$out" "  manual: reboot pending"
}

test_run_duplicate_first_domain_fails_both() {
	local out
	setup_instance
	add_device a noop
	write_device "$DIR" b 'DOMAINS=a.example.com' 'ADDRESS=127.0.0.1'
	add_device c renew-ok
	out=$(run_cli run)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "  a: FAILED: first domain a.example.com is also used by another device"
	assert_contains "$out" "  b: FAILED: first domain a.example.com is also used by another device"
	assert_contains "$out" "  c: new certificate deployed"
	assert_eq "device=c" "$(cut -d' ' -f1 "$LEGO_DIR/calls")" "lego calls"
}

test_run_broken_device_config_fails_only_that_device() {
	local out
	setup_instance
	write_device "$DIR" broken 'ADDRESS=127.0.0.1'
	add_device good renew-ok
	out=$(run_cli run)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "missing required key DOMAINS"
	assert_contains "$out" "  broken: FAILED: config has errors, run 'shelly-certs validate'"
	assert_contains "$out" "  good: new certificate deployed"
}

test_run_dry_run_changes_nothing() {
	local out
	setup_instance
	add_device withcert noop
	make_cert "$DIR/data/certificates" withcert.example.com ec withcert.example.com
	add_device nocert renew-ok
	mkdir -p "$DIR/data/status"
	echo "ok old" >"$DIR/data/status/withcert.hook"
	out=$(run_cli run --dry-run)
	assert_eq 0 "$?" "exit code"
	assert_eq 0 "$(wc -l <"$LEGO_DIR/calls")" "number of lego calls"
	assert_contains "$out" "nocert: dry run: would run in $DIR: SHELLY_CERTS_DEVICE=nocert lego --log.format text run"
	assert_contains "$out" "nocert: dry run: no local certificate yet, lego would request one and the hook would deploy it"
	assert_contains "$out" "withcert: dry run: lego would renew only if the certificate is due"
	assert_contains "$out" "withcert: dry run: would call Shelly.PutHTTPServerCert"
	assert_eq "ok old" "$(cat "$DIR/data/status/withcert.hook")" "status file"
	[[ ! -e $DIR/data/certificates/nocert.example.com.crt ]] || fail "dry run created a certificate"
}

test_run_force_warns_and_passes_renew_force() {
	local out
	setup_instance
	add_device dev noop
	out=$(run_cli run --dry-run --force)
	assert_contains "$out" "WARNING: --force renews every selected certificate now. Let's Encrypt allows only 5 certificates for the same set of names per week"
	assert_contains "$out" "--renew-force"
}

test_run_bad_arguments() {
	local out
	setup_instance
	add_device dev noop
	out=$(run_cli run --bogus)
	assert_eq 2 "$?" "exit code"
	assert_contains "$out" "run: unknown option --bogus"
	out=$(run_cli run --device nope)
	assert_eq 2 "$?" "exit code"
	assert_contains "$out" "no device config $DIR/config/devices.d/nope.conf"
	out=$(run_cli run --device)
	assert_eq 2 "$?" "exit code"
	assert_contains "$out" "--device needs a device name"
	assert_eq 0 "$(wc -l <"$LEGO_DIR/calls")" "number of lego calls"
}

test_run_refuses_while_locked() {
	local out
	setup_instance
	add_device dev noop
	(
		exec 8>"$DIR/data/.lock"
		flock 8
		sleep 3
	) &
	sleep 0.5
	out=$(run_cli run)
	assert_eq 1 "$?" "exit code"
	assert_contains "$out" "another shelly-certs process holds $DIR/data/.lock"
	wait
}

run_tests
