# shellcheck shell=bash
# Talks to a Shelly Gen2+ device over its RPC API and deploys a certificate to it.
# Device side: https://shelly-api-docs.shelly.cloud/gen2/General/CustomHTTPSCertificates/
# `shelly-certs deploy`, the drift check in `shelly-certs run` and bin/shelly-deploy-hook all call
# deploy_device. Needs CFG and DEV loaded (lib/config.sh) and WORKDIR set (make_workdir) for uploads.

# Base URL for RPC calls and extra curl arguments (--resolve, --cacert or --insecure).
# shelly_pick_transport sets them.
SHELLY_BASE_URL=""
SHELLY_CURL_ARGS=()
# 1 = print the RPC calls deploy_device would make and change nothing. Only `run --dry-run` sets it.
DRY_RUN=0

# Prints a curl config line with the device user and password. Quotes and backslashes are escaped
# the way curl config files expect.
shelly_auth_config() {
	local user=${DEV[SHELLY_USER]} password=""
	IFS= read -r password <"${DEV[SHELLY_PASSWORD_FILE]}" || true
	user=${user//\\/\\\\}
	user=${user//\"/\\\"}
	password=${password//\\/\\\\}
	password=${password//\"/\\\"}
	printf 'user = "%s:%s"\n' "$user" "$password"
}

# Runs curl against the device with SHELLY_CURL_ARGS. When the device has a password, curl uses
# HTTP digest auth and gets user and password through a config on stdin, so they never show up in
# the process list.
# It must be --anyauth, not --digest: with --digest curl's first POST has an empty body, and the
# device answers that with 400 instead of the 401 that tells curl how to log in. --anyauth sends the
# full body first, gets the 401, then sends it again with the login.
shelly_curl() {
	local -a args=(--silent --show-error --connect-timeout 10 --max-time 60 "${SHELLY_CURL_ARGS[@]}")
	if [[ -n ${DEV[SHELLY_PASSWORD_FILE]} ]]; then
		shelly_auth_config | curl --config - --anyauth "${args[@]}" "$@"
	else
		curl "${args[@]}" "$@" </dev/null
	fi
}

# rpc_result METHOD HTTP_CODE BODY prints the "result" of an RPC answer as JSON, or prints why the
# call failed and returns 1.
rpc_result() {
	local method=$1 code=$2 body=$3
	if [[ $code == 401 ]]; then
		err "$method failed: authentication failed (HTTP 401), check SHELLY_PASSWORD_FILE and SHELLY_USER"
		return 1
	fi
	if jq -e 'type == "object" and has("error")' >/dev/null 2>&1 <<<"$body"; then
		err "$method failed: $(jq -r '.error | "error \(.code): \(.message)"' <<<"$body")"
		return 1
	fi
	if [[ $code != 200 ]]; then
		err "$method failed: HTTP $code: ${body:0:200}"
		return 1
	fi
	if ! jq -e 'type == "object" and has("result")' >/dev/null 2>&1 <<<"$body"; then
		err "$method failed: unexpected answer: ${body:0:200}"
		return 1
	fi
	jq -c '.result' <<<"$body"
}

# shelly_post METHOD CURL_DATA_ARG POSTs a JSON-RPC request to /rpc and prints the result.
# CURL_DATA_ARG is what curl's --data-binary gets: the JSON itself or @file.
shelly_post() {
	local method=$1 data=$2 out
	out=$(shelly_curl -X POST -H 'Content-Type: application/json' --data-binary "$data" \
		-w '\n%{http_code}' "$SHELLY_BASE_URL/rpc") || {
		err "$method failed: could not reach $SHELLY_BASE_URL"
		return 1
	}
	rpc_result "$method" "${out##*$'\n'}" "${out%$'\n'*}"
}

# shelly_rpc METHOD PARAMS_JSON calls a method with small, non-secret params. The JSON goes on
# curl's command line, where `ps` can see it; uploads go through files instead (shelly_upload).
shelly_rpc() {
	local body
	body=$(jq -cn --arg m "$1" --argjson p "$2" '{id: 1, method: $m, params: $p}')
	shelly_post "$1" "$body"
}

# build_upload_body METHOD FILE OUT writes the JSON-RPC request that uploads FILE to OUT.
# Without `append` the device replaces the file it has.
build_upload_body() {
	jq -Rs --arg m "$1" '{id: 1, method: $m, params: {data: .}}' <"$2" >"$3"
}

# shelly_upload METHOD FILE uploads FILE with PutHTTPServerCert or PutHTTPServerKey and prints the
# device's answer. Fails if the size the device reports differs from the file.
shelly_upload() {
	local method=$1 file=$2 body result size len
	body=$(mktemp "$WORKDIR/upload.XXXXXX")
	build_upload_body "$method" "$file" "$body"
	if ! result=$(shelly_post "$method" "@$body"); then
		rm -f "$body"
		return 1
	fi
	rm -f "$body"
	size=$(stat -c %s "$file")
	len=$(jq -r '.len // empty' <<<"$result")
	if [[ $len != "$size" ]]; then
		err "$method: the device reports ${len:-no} bytes stored, but $file has $size bytes"
		return 1
	fi
	printf '%s\n' "$result"
}

# Prints the IP address to use for ADDRESS, because curl's --resolve needs an IP address.
# IP addresses are returned as they are.
shelly_resolve_ip() {
	local address=$1 ip
	if [[ $address =~ ^[0-9.]+$ || $address == *:* ]]; then
		printf '%s\n' "$address"
		return
	fi
	ip=$(getent ahosts "$address" | awk 'NR == 1 {print $1}')
	[[ -n $ip ]] || return 1
	printf '%s\n' "$ip"
}

# IPv6 addresses need brackets in URLs and in curl's --resolve.
url_host() {
	if [[ $1 == *:* ]]; then printf '[%s]\n' "$1"; else printf '%s\n' "$1"; fi
}

# Sets SHELLY_BASE_URL and SHELLY_CURL_ARGS for verified HTTPS to the device's first domain.
use_verified_https() {
	local host=$1
	SHELLY_BASE_URL="https://${DEV[FIRST_DOMAIN]}"
	SHELLY_CURL_ARGS=(--resolve "${DEV[FIRST_DOMAIN]}:443:$host")
	if [[ -n ${CFG[DEVICE_CA_FILE]} ]]; then
		SHELLY_CURL_ARGS+=(--cacert "${CFG[DEVICE_CA_FILE]}")
	fi
}

# Picks how to talk to the device, in this order:
#  1. https://FIRST_DOMAIN (sent to ADDRESS with --resolve) with normal certificate checks.
#  2. http://ADDRESS, when the device answers there without redirecting to HTTPS.
#  3. https://FIRST_DOMAIN without certificate checks, only with ALLOW_INSECURE_DEPLOY=yes.
shelly_pick_transport() {
	local ip host code
	ip=$(shelly_resolve_ip "${DEV[ADDRESS]}") || {
		err "cannot resolve ${DEV[ADDRESS]}"
		return 1
	}
	host=$(url_host "$ip")

	use_verified_https "$host"
	if shelly_curl --max-time 15 -o /dev/null "$SHELLY_BASE_URL/rpc/Shelly.GetDeviceInfo" 2>/dev/null; then
		log "connecting over HTTPS with certificate check"
		return 0
	fi

	SHELLY_BASE_URL="http://$host"
	SHELLY_CURL_ARGS=()
	code=$(shelly_curl --max-time 15 -o /dev/null -w '%{http_code}' "$SHELLY_BASE_URL/rpc/Shelly.GetDeviceInfo" 2>/dev/null) || code=000
	# 401 means the device answered and wants a login, so HTTP works.
	if [[ $code == 2?? || $code == 401 ]]; then
		warn "HTTPS with certificate check failed, using plain HTTP: the private key travels unencrypted over the local network"
		return 0
	fi

	if [[ ${CFG[ALLOW_INSECURE_DEPLOY]} == yes ]]; then
		use_verified_https "$host"
		SHELLY_CURL_ARGS=(--resolve "${DEV[FIRST_DOMAIN]}:443:$host" --insecure)
		if shelly_curl --max-time 15 -o /dev/null "$SHELLY_BASE_URL/rpc/Shelly.GetDeviceInfo" 2>/dev/null; then
			warn "using HTTPS WITHOUT certificate check (ALLOW_INSECURE_DEPLOY=yes)"
			return 0
		fi
		err "device does not answer at ${DEV[ADDRESS]} over HTTPS or HTTP"
		return 1
	fi
	if [[ $code == 3?? ]]; then
		err "HTTPS with certificate check failed and HTTP redirects to HTTPS. Set ALLOW_INSECURE_DEPLOY=yes to deploy over HTTPS without certificate check (see docs/troubleshooting.md)"
	else
		err "device does not answer at ${DEV[ADDRESS]}: HTTPS with certificate check failed and HTTP gave status $code"
	fi
	return 1
}

# Polls until the device serves the certificate with fingerprint $1, up to REBOOT_TIMEOUT seconds.
shelly_wait_for_cert() {
	local fp=$1 deadline served
	deadline=$((SECONDS + CFG[REBOOT_TIMEOUT]))
	# Give the device time to actually go down, so we don't read the old certificate as "back".
	sleep 5
	while ((SECONDS < deadline)); do
		served=$(served_fingerprint "${DEV[ADDRESS]}" "${DEV[FIRST_DOMAIN]}" 2>/dev/null) || served=""
		[[ $served == "$fp" ]] && return 0
		sleep 3
	done
	return 1
}

# Explains why the device doesn't serve the new certificate after the reboot.
shelly_explain_missing_cert() {
	local served code
	served=$(served_fingerprint "${DEV[ADDRESS]}" "${DEV[FIRST_DOMAIN]}" 2>/dev/null) || served=""
	if [[ -n $served ]]; then
		err "after ${CFG[REBOOT_TIMEOUT]}s the device still serves another certificate ($served)"
		return
	fi
	code=$(curl --silent --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' \
		"http://$(url_host "$(shelly_resolve_ip "${DEV[ADDRESS]}")")/rpc/Shelly.GetDeviceInfo") || code=000
	if [[ $code != 000 ]]; then
		err "the device answers on HTTP but serves no HTTPS. This usually means it found that cert and key don't match and skipped HTTPS; check the device log (see docs/troubleshooting.md)"
	else
		err "the device did not come back within REBOOT_TIMEOUT (${CFG[REBOOT_TIMEOUT]}s)"
	fi
}

# Prints an upper limit in seconds for one deploy_device call; `run` gives it to lego as
# --deploy-hook-timeout. If lego stopped the hook halfway, the device could end up with the new
# certificate and the old key. The parts: 3 transport probes (15s each), the two uploads (60s
# each), Shelly.Reboot (60s), waiting for the certificate (5s + REBOOT_TIMEOUT + one last poll
# of up to 13s), the final HTTPS check (60s), and 30s to spare.
deploy_worst_case_seconds() {
	echo $((3 * 15 + 2 * 60 + 60 + 5 + CFG[REBOOT_TIMEOUT] + 13 + 60 + 30))
}

# The marker records that a certificate was uploaded to a REBOOT=manual device and is waiting for a reboot.
pending_marker() { printf '%s\n' "$SC_STATUS_DIR/${DEV[NAME]}.pending"; }

# deploy_device CERT KEY uploads CERT (full chain) and KEY to the device in DEV, then reboots it
# and checks it serves the new certificate (REBOOT=auto), or leaves the reboot to the user
# (REBOOT=manual).
deploy_device() {
	local cert=$1 key=$2 fp missing result restart
	local -a domains
	read -r -a domains <<<"${DEV[DOMAINS]}"

	if [[ ! -f $cert ]]; then
		err "certificate file $cert does not exist"
		return 1
	fi
	if [[ ! -f $key ]]; then
		err "key file $key does not exist"
		return 1
	fi
	if ! cert_key_match "$cert" "$key"; then
		err "key $key does not belong to certificate $cert"
		return 1
	fi
	if ! missing=$(cert_missing_domains "$cert" "${domains[@]}"); then
		err "certificate $cert does not cover: ${missing//$'\n'/ }"
		return 1
	fi
	fp=$(cert_fingerprint "$cert")

	if [[ $DRY_RUN == 1 ]]; then
		log "dry run: would call Shelly.PutHTTPServerCert with $cert"
		log "dry run: would call Shelly.PutHTTPServerKey with $key"
		if [[ ${DEV[REBOOT]} == auto ]]; then
			log "dry run: would call Shelly.Reboot and wait up to ${CFG[REBOOT_TIMEOUT]}s for the new certificate"
		else
			log "dry run: REBOOT=manual, would not reboot"
		fi
		return 0
	fi

	shelly_pick_transport || return 1
	log "uploading certificate $fp"
	shelly_upload Shelly.PutHTTPServerCert "$cert" >/dev/null || return 1
	log "uploading key"
	if ! result=$(shelly_upload Shelly.PutHTTPServerKey "$key"); then
		err "the device now has the new certificate but not its key; it will drop HTTPS at its next reboot until a deploy succeeds"
		return 1
	fi
	restart=$(jq -r '.restart_required' <<<"$result")
	if [[ $restart != true ]]; then
		err "after the key upload the device answered restart_required=$restart, so it does not see a matching cert and key. Not rebooting"
		return 1
	fi

	mkdir -p "$SC_STATUS_DIR"
	if [[ ${DEV[REBOOT]} == manual ]]; then
		printf '%s\n' "$fp" >"$(pending_marker)"
		log "uploaded. REBOOT=manual: reboot the device yourself to start using the new certificate"
		return 0
	fi

	log "rebooting, waiting up to ${CFG[REBOOT_TIMEOUT]}s for the new certificate"
	shelly_rpc Shelly.Reboot '{}' >/dev/null || warn "the reboot call did not answer cleanly, waiting for the device anyway"
	if ! shelly_wait_for_cert "$fp"; then
		shelly_explain_missing_cert
		return 1
	fi
	use_verified_https "$(url_host "$(shelly_resolve_ip "${DEV[ADDRESS]}")")"
	if ! shelly_curl --fail -o /dev/null "$SHELLY_BASE_URL/rpc/Shelly.GetDeviceInfo"; then
		err "the device serves the new certificate, but HTTPS with certificate check to $SHELLY_BASE_URL fails (with staging, set DEVICE_CA_FILE)"
		return 1
	fi
	rm -f "$(pending_marker)"
	log "deployed: the device serves $fp"
}
