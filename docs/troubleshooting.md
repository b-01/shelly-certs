# Troubleshooting

## lego can't verify the DNS record

The errors mention "propagation", "NXDOMAIN" or "time limit exceeded". Before lego asks Let's
Encrypt to check the TXT record, it asks every nameserver of your zone whether the record is
there. It keeps asking until the DNS provider's propagation timeout runs out (60 seconds for
Hetzner).

- The nameservers never get the record: check that the API token can write to the zone that
  holds your domains.
- The provider takes longer than the timeout to publish the record: raise the timeout in
  `secrets/dns.env`, for example `HETZNER_PROPAGATION_TIMEOUT=180`. `lego dnshelp -c PROVIDER`
  shows the name of the setting for your provider.
- Split DNS: lego uses `DNS_RESOLVERS` to find your zone and its nameservers. If your local
  resolver answers for the zone itself, lego asks the wrong servers. Set `DNS_RESOLVERS` to public
  resolvers (the example uses `1.1.1.1:53,9.9.9.9:53`).

lego doesn't wait until public resolvers like 1.1.1.1 see the record (`--dns.propagation.disable-rns`,
the same as Traefik's default). They often still remember the "no such name" answer from before
the record existed, longer than the timeout, and Let's Encrypt doesn't use them anyway.

## "authentication failed (HTTP 401)"

The password file must hold the password on its first
line. The user is `admin` on Shelly Gen2+; leave `SHELLY_USER` out unless you know otherwise.

## "HTTP redirects to HTTPS"

The full error is "HTTPS with certificate check failed and HTTP redirects to HTTPS". shelly-certs
couldn't connect over HTTPS because the device's certificate didn't pass the check, and it couldn't
fall back to plain HTTP because the device sends HTTP requests on to HTTPS. The check usually fails
because:

- The device still serves a staging certificate, but you switched to production and emptied
  `DEVICE_CA_FILE`, so your system no longer trusts it.
- The device's certificate has expired, or it isn't valid for the first name in `DOMAINS`.

To get the current certificate onto the device anyway, set `ALLOW_INSECURE_DEPLOY=yes` in
`config/shelly-certs.conf`, run `sudo -u shelly-certs ./bin/shelly-certs deploy NAME`, then set it
back to `no`. The comment above the setting explains the risk.

## The device answers only on HTTP after the reboot

The error says the device "serves no HTTPS". The device didn't
accept the certificate and key as a pair. If the two don't match, or only one is set, it skips
HTTPS without an error and keeps serving plain HTTP. Run `shelly-certs deploy NAME` again and
read the device log.

## Reading the device log

By default the device keeps no log you can read later, but you can watch its live log. Start this
in a second terminal, then run `shelly-certs deploy NAME` in the first one:
```sh
curl --digest -u admin 'http://ADDRESS/debug/log'
```
curl asks for the password; leave out `--digest -u admin` if the device has none. Look for lines
about HTTPS or certificates. The stream ends when the device reboots. Start it again right away
to see what the device does after the reboot, though you may miss the first few seconds. The
device can also store its log or send it over UDP or MQTT, so it survives reboots, but you have
to turn that on first. See the Shelly docs on [debug logs](https://shelly-api-docs.shelly.cloud/gen2/General/DebugLogs).

## "lego saved a new certificate, but the deploy hook reports ..."

The certificate is saved
locally but didn't reach the device. The next run deploys it, or run `shelly-certs deploy NAME`.

## The service fails with "Permission denied"

Some file in `data/` or `secrets/` isn't owned by
`shelly-certs` (usually after running a command as root). Run `sudo ./install.sh` again.
