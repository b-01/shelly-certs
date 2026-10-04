#!/usr/bin/env bash
# Staging test: runs shelly-certs against Let's Encrypt staging, Hetzner DNS and real devices, with
# the settings from tests/staging.env (see tests/staging.env.example). It works on a throwaway copy
# of the tool, so the real config, secrets and certificates are never touched.
#
# The steps build on each other, so the test stops at the first failing one. The copy is kept when
# a step fails (the path is printed) and removed when every step passed.
set -uo pipefail
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

# The parsing helpers from lib/config.sh read tests/staging.env the same way as the real config.
SC_ROOT=$REPO_ROOT
# shellcheck source=../../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$REPO_ROOT/lib/config.sh"

ENV_FILE="$REPO_ROOT/tests/staging.env"
STAGING_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
STAGING_ROOTS=(https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem
	https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x2.pem)

declare -A ST=()
INSTANCE=""
OUT=""
RC=0

# Reads tests/staging.env into ST and checks it. Exits with 2 when something is missing.
load_settings() {
	local n
	if [[ ! -f $ENV_FILE ]]; then
		err "copy tests/staging.env.example to tests/staging.env and fill it in"
		exit 2
	fi
	kv_parse "$ENV_FILE" ST ACME_EMAIL HETZNER_API_TOKEN_FILE DNS_RESOLVERS KEY_TYPE REBOOT_TIMEOUT \
		ALLOW_INSECURE_DEPLOY DEVICE1_DOMAINS DEVICE1_ADDRESS DEVICE1_PASSWORD_FILE \
		DEVICE2_DOMAINS DEVICE2_ADDRESS DEVICE2_PASSWORD_FILE || exit 2
	require_keys "$ENV_FILE" ST ACME_EMAIL HETZNER_API_TOKEN_FILE DEVICE1_DOMAINS DEVICE1_ADDRESS || exit 2
	: "${ST[DNS_RESOLVERS]:=1.1.1.1:53,9.9.9.9:53}"
	: "${ST[KEY_TYPE]:=ec256}"
	: "${ST[REBOOT_TIMEOUT]:=120}"
	: "${ST[ALLOW_INSECURE_DEPLOY]:=no}"
	ST[HETZNER_API_TOKEN_FILE]=$(abs_path "${ST[HETZNER_API_TOKEN_FILE]}")
	[[ -f ${ST[HETZNER_API_TOKEN_FILE]} ]] || die "$ENV_FILE: HETZNER_API_TOKEN_FILE: file ${ST[HETZNER_API_TOKEN_FILE]} does not exist"
	for n in 1 2; do
		if [[ -n ${ST[DEVICE${n}_PASSWORD_FILE]:-} ]]; then
			ST[DEVICE${n}_PASSWORD_FILE]=$(abs_path "${ST[DEVICE${n}_PASSWORD_FILE]}")
		fi
	done
	if [[ -n ${ST[DEVICE2_DOMAINS]:-} || -n ${ST[DEVICE2_ADDRESS]:-} ]]; then
		[[ -n ${ST[DEVICE2_DOMAINS]:-} && -n ${ST[DEVICE2_ADDRESS]:-} ]] ||
			die "$ENV_FILE: set both DEVICE2_DOMAINS and DEVICE2_ADDRESS, or neither"
		[[ ${ST[DEVICE2_ADDRESS]} != "${ST[DEVICE1_ADDRESS]}" ]] ||
			die "$ENV_FILE: the second device must be another physical device (DEVICE2_ADDRESS = DEVICE1_ADDRESS)"
	fi
	command -v lego >/dev/null || die "lego is not installed"
}

# write_test_device NAME N writes the device config for device N of tests/staging.env.
write_test_device() {
	local name=$1 n=$2
	local -a lines=("DOMAINS=${ST[DEVICE${n}_DOMAINS]}" "ADDRESS=${ST[DEVICE${n}_ADDRESS]}")
	[[ -z ${ST[DEVICE${n}_PASSWORD_FILE]:-} ]] || lines+=("SHELLY_PASSWORD_FILE=${ST[DEVICE${n}_PASSWORD_FILE]}")
	write_device "$INSTANCE" "$name" "${lines[@]}"
}

# Creates the throwaway copy of the tool with a staging config and the first device.
make_staging_instance() {
	INSTANCE=$(mktemp -d "${TMPDIR:-/tmp}/shelly-certs-staging.XXXXXX")
	cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$INSTANCE/"
	mkdir -p "$INSTANCE/config/devices.d" "$INSTANCE/secrets" "$INSTANCE/data"
	chmod 700 "$INSTANCE/secrets"
	printf 'HETZNER_API_TOKEN_FILE=%s\n' "${ST[HETZNER_API_TOKEN_FILE]}" >"$INSTANCE/secrets/dns.env"
	chmod 600 "$INSTANCE/secrets/dns.env"
	# The check after a deploy verifies the device's certificate, which needs the staging roots.
	curl -sSf "${STAGING_ROOTS[@]}" >"$INSTANCE/data/letsencrypt-staging-roots.pem" ||
		die "could not download the staging root certificates"
	printf '%s\n' "ACME_EMAIL=${ST[ACME_EMAIL]}" "ACME_SERVER=$STAGING_SERVER" 'DNS_PROVIDER=hetzner' \
		'DNS_ENV_FILE=secrets/dns.env' "DNS_RESOLVERS=${ST[DNS_RESOLVERS]}" "KEY_TYPE=${ST[KEY_TYPE]}" \
		'RENEW_DAYS=30' "REBOOT_TIMEOUT=${ST[REBOOT_TIMEOUT]}" "ALLOW_INSECURE_DEPLOY=${ST[ALLOW_INSECURE_DEPLOY]}" \
		'DEVICE_CA_FILE=data/letsencrypt-staging-roots.pem' >"$INSTANCE/config/shelly-certs.conf"
	write_test_device first 1
}

# cli ARGS... runs the copy's shelly-certs, shows its output indented and sets OUT and RC.
cli() {
	printf '  $ shelly-certs %s\n' "$*"
	OUT=$("$INSTANCE/bin/shelly-certs" "$@" 2>&1)
	RC=$?
	printf '    | %s\n' "${OUT//$'\n'/$'\n'    | }"
}

# with_device NAME COMMAND... runs COMMAND in a subshell with the copy's libraries loaded and DEV
# set to device NAME, so the test can use the same functions the tool uses.
with_device() {
	local name=$1
	shift
	(
		SC_ROOT=$INSTANCE
		# shellcheck source=../../lib/common.sh
		source "$INSTANCE/lib/common.sh"
		# shellcheck source=../../lib/config.sh
		source "$INSTANCE/lib/config.sh"
		# shellcheck source=../../lib/certs.sh
		source "$INSTANCE/lib/certs.sh"
		# shellcheck source=../../lib/shelly.sh
		source "$INSTANCE/lib/shelly.sh"
		load_global_config && load_device "$name" || exit 1
		make_workdir
		"$@"
	)
}

# These run inside with_device, which sets DEV.
# shellcheck disable=SC2031
served_fp() { served_fingerprint "${DEV[ADDRESS]}" "${DEV[FIRST_DOMAIN]}"; }
reboot_device() { shelly_pick_transport && shelly_rpc Shelly.Reboot '{}' >/dev/null; }

# Fingerprint of the local certificate whose name is DOMAIN.
local_fp() {
	openssl x509 -in "$INSTANCE/data/certificates/$1.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
}

# The DEVICE_CERT column of `status` for device NAME.
device_state() {
	"$INSTANCE/bin/shelly-certs" status 2>/dev/null | awk -v n="$1" '$1 == n {print $5}'
}

FIRST1=""
FIRST2=""
FP1=""

step_validate() {
	cli validate
	assert_eq 0 "$RC" "exit code"
}

step_dry_run() {
	cli run --dry-run
	assert_eq 0 "$RC" "exit code"
	assert_contains "$OUT" "first: dry run: no local certificate yet"
	[[ ! -e $INSTANCE/data/certificates/$FIRST1.crt ]] || fail "the dry run created a certificate"
}

step_first_run_issues_and_deploys() {
	cli run
	assert_eq 0 "$RC" "exit code"
	assert_contains "$OUT" "  first: new certificate deployed"
	FP1=$(local_fp "$FIRST1")
	[[ -n $FP1 ]] || fail "no local certificate for $FIRST1"
	assert_eq "$FP1" "$(with_device first served_fp)" "certificate the device serves"
	assert_eq yes "$(device_state first)" "status"
}

step_second_run_changes_nothing() {
	cli run
	assert_eq 0 "$RC" "exit code"
	assert_contains "$OUT" "  first: up to date"
	assert_eq "$FP1" "$(local_fp "$FIRST1")" "local certificate"
}

step_new_device_leaves_first_alone() {
	write_test_device second 2
	cli run
	assert_eq 0 "$RC" "exit code"
	assert_contains "$OUT" "  second: new certificate deployed"
	assert_contains "$OUT" "  first: up to date"
	assert_eq "$FP1" "$(local_fp "$FIRST1")" "first device's local certificate"
	assert_eq "$(local_fp "$FIRST2")" "$(with_device second served_fp)" "certificate the second device serves"
}

step_deploy_over_verified_https() {
	cli deploy first
	assert_eq 0 "$RC" "exit code"
	assert_contains "$OUT" "first: connecting over HTTPS with certificate check"
	assert_contains "$OUT" "first: deployed: the device serves $FP1"
}

# Puts a self-signed certificate on the device (like a factory reset or a foreign deploy would
# leave another certificate there), then checks that `run` notices and deploys the right one.
step_run_repairs_drift() {
	local -a domains
	local self_fp
	read -r -a domains <<<"${ST[DEVICE1_DOMAINS]}"
	make_cert "$TEST_TMP" selfsigned ec "${domains[@]}"
	self_fp=$(openssl x509 -in "$TEST_TMP/selfsigned.crt" -noout -fingerprint -sha256 | sed 's/.*=//')
	printf '  putting a self-signed certificate on the device (the final check of this deploy is expected to fail)\n'
	with_device first deploy_device "$TEST_TMP/selfsigned.crt" "$TEST_TMP/selfsigned.key" 2>&1 | sed 's/^/    | /'
	assert_eq "$self_fp" "$(with_device first served_fp)" "certificate the device serves after the self-signed deploy"
	cli run --device first
	assert_eq 0 "$RC" "exit code"
	assert_contains "$OUT" "first: the device serves another certificate, deploying the local certificate"
	assert_contains "$OUT" "  first: deployed"
	assert_eq "$FP1" "$(with_device first served_fp)" "certificate the device serves after run"
}

step_manual_reboot() {
	local new_fp deadline state=""
	printf 'REBOOT=manual\n' >>"$INSTANCE/config/devices.d/first.conf"
	cli run --force --device first
	assert_eq 0 "$RC" "exit code"
	assert_contains "$OUT" "  first: new certificate uploaded, reboot pending"
	new_fp=$(local_fp "$FIRST1")
	[[ $new_fp != "$FP1" ]] || fail "--force did not renew the certificate"
	assert_eq pending-reboot "$(device_state first)" "status before the reboot"
	printf '  rebooting the device\n'
	with_device first reboot_device 2>&1 | sed 's/^/    | /'
	deadline=$((SECONDS + ST[REBOOT_TIMEOUT] + 30))
	sleep 5
	while ((SECONDS < deadline)); do
		state=$(device_state first)
		[[ $state == yes ]] && break
		sleep 3
	done
	sed -i '/^REBOOT=/d' "$INSTANCE/config/devices.d/first.conf"
	assert_eq yes "$state" "status after the reboot"
	FP1=$new_fp
}

step_prune() {
	if [[ -z $FIRST2 ]]; then
		cli prune
		assert_eq 0 "$RC" "exit code"
		assert_contains "$OUT" "no unused certificates"
		return
	fi
	rm "$INSTANCE/config/devices.d/second.conf"
	cli prune
	assert_contains "$OUT" "unused certificate: $FIRST2"
	cli prune --yes
	assert_eq 0 "$RC" "exit code"
	[[ ! -e $INSTANCE/data/certificates/$FIRST2.crt ]] || fail "prune --yes left $FIRST2.crt"
	[[ -e $INSTANCE/data/certificates/$FIRST1.crt ]] || fail "prune --yes deleted $FIRST1.crt"
}

# step NAME runs step_NAME and stops the whole test when it fails.
step() {
	local before=$TESTS_FAILED
	printf '%s\n' "$1"
	"step_$1"
	if ((TESTS_FAILED == before)); then
		printf '  ok   %s\n' "$1"
		return
	fi
	printf '  FAIL %s\n' "$1"
	printf 'Stopped. The test copy is kept at %s (it holds staging certificates and keys).\n' "$INSTANCE"
	exit 1
}

load_settings
FIRST1=${ST[DEVICE1_DOMAINS]%% *}
FIRST2=${ST[DEVICE2_DOMAINS]:-}
FIRST2=${FIRST2%% *}
make_staging_instance
printf 'Staging test in %s\n' "$INSTANCE"
step validate
step dry_run
step first_run_issues_and_deploys
step second_run_changes_nothing
if [[ -n $FIRST2 ]]; then
	step new_device_leaves_first_alone
else
	printf 'new_device_leaves_first_alone\n  skipped: no second device in tests/staging.env\n'
fi
step deploy_over_verified_https
step run_repairs_drift
step manual_reboot
step prune
rm -rf "$INSTANCE"
printf 'all staging steps passed. The devices now serve staging certificates.\n'
