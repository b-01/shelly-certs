# Tests

`tests/run-tests.sh` runs shellcheck over every script and the offline tests in `tests/unit/`.

`tests/staging/run-staging-tests.sh` tests the whole tool against Let's Encrypt staging, Hetzner DNS and one or two real devices. Copy `tests/staging.env.example` to `tests/staging.env` and fill it in first. It works on a throwaway copy of the tool, so your config and certificates aren't touched, but it reboots the devices several times and leaves them serving a staging certificate.

`run-staging-tests` checks: 
 - issuing and deploying of Let's Encrypt certificates (against staging servers)
 - that a second run does not change anything 
 - that adding a second device does not change the first one 
 - deploys over verified HTTPS 
 - that `run` repairs a device serving a different certificate
 - `REBOOT=manual` 
 - `prune`
