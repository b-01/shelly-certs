# shellcheck shell=bash
# Helpers for local certificate files and the certificate a device serves.

# lego names cert files after the cert name. We always use the first domain as cert name, and a
# valid lowercase host name is stored unchanged.
cert_path() { printf '%s\n' "$SC_CERT_DIR/$1.crt"; }
key_path() { printf '%s\n' "$SC_CERT_DIR/$1.key"; }

# Prints the SHA-256 fingerprint (AA:BB:...) of the first certificate in a PEM file, which is the
# leaf certificate in lego's bundle.
cert_fingerprint() {
	local out
	out=$(openssl x509 -in "$1" -noout -fingerprint -sha256) || return 1
	printf '%s\n' "${out#*=}"
}

# Prints the expiry of the first certificate as seconds since 1970.
cert_not_after_epoch() {
	local out
	out=$(openssl x509 -in "$1" -noout -enddate) || return 1
	date -u -d "${out#notAfter=}" +%s
}

# Prints the expiry date of the first certificate as YYYY-MM-DD (UTC).
cert_expiry_date() {
	local epoch
	epoch=$(cert_not_after_epoch "$1") || return 1
	date -u -d "@$epoch" +%Y-%m-%d
}

# Prints the number of whole days until the first certificate expires (negative when expired).
cert_days_left() {
	local epoch now
	epoch=$(cert_not_after_epoch "$1") || return 1
	now=$(date +%s)
	printf '%s\n' $(((epoch - now) / 86400))
}

# cert_key_match CERT KEY succeeds when the key belongs to the first certificate in CERT.
cert_key_match() {
	local cert_pub key_pub
	cert_pub=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null) || return 1
	key_pub=$(openssl pkey -in "$2" -pubout 2>/dev/null) || return 1
	[[ -n $cert_pub && $cert_pub == "$key_pub" ]]
}

# cert_missing_domains CERT DOMAIN... prints each domain that is not a DNS name in the
# certificate's subjectAltName, and fails if there is any.
cert_missing_domains() {
	local cert=$1 sans domain rc=0
	shift
	sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) || return 1
	sans=" $(tr -d ' \n' <<<"${sans#*Alternative Name:}" | tr ',' ' ') "
	for domain in "$@"; do
		if [[ $sans != *" DNS:$domain "* ]]; then
			printf '%s\n' "$domain"
			rc=1
		fi
	done
	return $rc
}

# served_fingerprint ADDRESS DOMAIN [PORT] connects to ADDRESS:PORT (default 443) with DOMAIN as
# SNI name and prints the SHA-256 fingerprint of the certificate the device serves. It doesn't
# check the certificate, it only reads it. Fails when there is no TLS answer within 10 seconds.
served_fingerprint() {
	local address=$1 domain=$2 port=${3:-443} pem
	[[ $address == *:* ]] && address="[$address]"
	pem=$(timeout 10 openssl s_client -connect "$address:$port" -servername "$domain" </dev/null 2>/dev/null |
		openssl x509 2>/dev/null) || return 1
	[[ -n $pem ]] || return 1
	cert_fingerprint /dev/stdin <<<"$pem"
}
