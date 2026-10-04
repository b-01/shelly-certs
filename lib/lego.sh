# shellcheck shell=bash
# Builds the lego call for one device; `shelly-certs run` uses it. Flags checked against lego v5.5.2.
# Needs CFG and DEV loaded (lib/config.sh), and lib/shelly.sh for the deploy hook timeout.

# lego_run_args ARRAY_NAME FORCE fills ARRAY_NAME with the lego command for the device in DEV.
# FORCE=1 adds --renew-force. `lego run` issues a certificate when there is none under --path and
# otherwise renews it only when it's due, when Let's Encrypt asks for it through its renewal info
# service (ARI), or when DOMAINS changed.
# The command holds file paths only: lego reads the DNS credentials from the --env-file itself.
lego_run_args() {
	local -n lra_out=$1
	local force=$2 domain
	local -a domains
	read -r -a domains <<<"${DEV[DOMAINS]}"
	lra_out=(lego --log.format text run --accept-tos
		--server "${CFG[ACME_SERVER]}" --email "${CFG[ACME_EMAIL]}"
		--path "$SC_DATA_DIR" --key-type "${CFG[KEY_TYPE]}"
		--dns "${CFG[DNS_PROVIDER]}" --env-file "${CFG[DNS_ENV_FILE]}"
		--cert.name "${DEV[FIRST_DOMAIN]}")
	for domain in "${domains[@]}"; do
		lra_out+=(--domains "$domain")
	done
	# --dns.propagation.disable-rns: before it asks Let's Encrypt, lego checks that the TXT record is
	# visible. By default it asks every authoritative nameserver of the zone and also every resolver
	# in --dns.resolvers. The resolvers often still remember the "no such name" answer from lego's
	# own lookup before the record existed (for as long as the zone's SOA allows, often longer than
	# the provider's propagation timeout), so the run fails although the record is in place. With
	# the flag lego asks only the authoritative nameservers, like Traefik does by default.
	# --force-cert-domains: without it lego keeps names removed from DOMAINS in the renewed cert.
	# --no-random-sleep: lego would sleep up to 8 minutes before each renewal (stdout isn't a
	# terminal under systemd), one device after the other, while we hold the lock. The timer's
	# RandomizedDelaySec already spreads the load on Let's Encrypt.
	lra_out+=(--dns.propagation.disable-rns
		--force-cert-domains --renew-days "${CFG[RENEW_DAYS]}" --no-random-sleep
		--deploy-hook "$SC_ROOT/bin/shelly-deploy-hook"
		--deploy-hook-timeout "$(deploy_worst_case_seconds)s")
	if [[ -n ${CFG[DNS_RESOLVERS]} ]]; then
		lra_out+=(--dns.resolvers "${CFG[DNS_RESOLVERS]}")
	fi
	if [[ $force == 1 ]]; then
		lra_out+=(--renew-force)
	fi
}
