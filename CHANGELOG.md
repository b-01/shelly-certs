# Changelog

## [0.1.0] - 2026-10-06

First release.

### Added

- Gets Let's Encrypt certificates for Shelly Gen2+ devices with lego v5 and the DNS-01
  challenge, so the devices never have to be reachable from the internet. Works with any DNS
  provider lego supports.
- Deploy hook that uploads a new certificate to the device over the Shelly RPC API, reboots the
  device and checks that it serves the new certificate.
- Daily systemd timer that renews certificates when needed and deploys again to any device that
  no longer serves the current certificate (for example after a factory reset or a failed
  deploy).
- One config file per device in `config/devices.d/`, plus a global config and a DNS credentials
  file in `secrets/`.
- `shelly-certs` commands: `run`, `deploy`, `status`, `list`, `validate`, `prune` and `help`.
- `install.sh`, `disable.sh` and `uninstall.sh` to set up, turn off and remove the install.
  `install.sh` refuses install folders under a home directory or with spaces in the path.
- Hardened systemd service (runs as its own `shelly-certs` user, `ProtectHome=yes` and more).
- Docs: README, `docs/troubleshooting.md` and `docs/testing.md`.

[0.1.0]: https://github.com/b-01/shelly-certs/releases/tag/v0.1.0
