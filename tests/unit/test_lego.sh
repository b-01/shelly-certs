#!/usr/bin/env bash
# Offline tests for building the lego command (lib/lego.sh) and the deploy hook timeout.
# shellcheck source=../lib/testlib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/testlib.sh"

SC_ROOT=$(make_instance)
write_global_config "$SC_ROOT" 'DNS_RESOLVERS=1.1.1.1:53,9.9.9.9:53'
write_device "$SC_ROOT" dev 'DOMAINS=a.example.com b.example.com' 'ADDRESS=192.0.2.10'
# shellcheck source=../../lib/common.sh
source "$SC_ROOT/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$SC_ROOT/lib/config.sh"
# shellcheck source=../../lib/certs.sh
source "$SC_ROOT/lib/certs.sh"
# shellcheck source=../../lib/shelly.sh
source "$SC_ROOT/lib/shelly.sh"
# shellcheck source=../../lib/lego.sh
source "$SC_ROOT/lib/lego.sh"
load_global_config
load_device dev

test_lego_args() {
	local -a args
	lego_run_args args 0
	assert_eq "lego --log.format text run --accept-tos \
--server https://acme-staging-v02.api.letsencrypt.org/directory --email admin@example.com \
--path $SC_ROOT/data --key-type ec256 --dns hetzner --env-file $SC_ROOT/secrets/dns.env \
--cert.name a.example.com --domains a.example.com --domains b.example.com \
--dns.propagation.disable-rns --force-cert-domains \
--renew-days 30 --no-random-sleep --deploy-hook $SC_ROOT/bin/shelly-deploy-hook \
--deploy-hook-timeout 453s --dns.resolvers 1.1.1.1:53,9.9.9.9:53" "${args[*]}"
	assert_not_contains "${args[*]}" "--no-bundle"
	assert_not_contains "${args[*]}" "--renew-force"
}

test_lego_args_force() {
	local -a args
	lego_run_args args 1
	assert_eq "--renew-force" "${args[-1]}" "last argument"
}

test_lego_args_without_resolvers() {
	local -a args
	CFG[DNS_RESOLVERS]=""
	lego_run_args args 0
	CFG[DNS_RESOLVERS]="1.1.1.1:53,9.9.9.9:53"
	assert_not_contains "${args[*]}" "--dns.resolvers"
}

test_deploy_worst_case() {
	# 3 probes at 15s, 2 uploads at 60s, reboot call 60s, 5s + REBOOT_TIMEOUT + 13s polling,
	# final check 60s, 30s to spare.
	assert_eq 453 "$(deploy_worst_case_seconds)"
}

run_tests
