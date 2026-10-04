# shelly-certs

>[!Warning]
>**DISCLAIMER**: This project has been created using AI (Claude Code - Opus 5.5 - High). Please create an issue/PR if you find/code potential for improvement.

**shelly-certs** gets Let's Encrypt certificates for [Shelly](https://www.shelly.com/collections/all-products) Gen2+ devices and installs them on the devices. It also implements a systemd service & timer to update the certificates if needed.

Under the hood it uses [lego](https://go-acme.github.io/lego/) to request and renew the certificates using the DNS-01 challenge at any [DNS provider](https://go-acme.github.io/lego/dns/index.html) lego supports. That way, the devices never have to be reachable from the internet.

Each device has its own config file. After acquiring a new certificate, lego calls a deploy hook that uploads it to the device over the [Shelly RPC API](https://shelly-api-docs.shelly.cloud/gen2/General/CustomHTTPSCertificates/#rpc-methods-for-server-certificates), reboots the device and checks that it serves the new certificate.

Additionally, a systemd timer runs every day and checks that every configured device still serves the current certificate and deploys again if not (e.g., factory reset, earlier failed deploy).

## Requirements

- Linux system with 
  - `systemd`
  - `lego` (v5+)
  - `bash`
  - `curl`
  - `jq`
  - `openssl`
  - util-linux (`flock`, `column`, `runuser`)
  - coreutils
- Shelly Gen2+ devices whose firmware supports [custom HTTPS certificates](https://shelly-api-docs.shelly.cloud/gen2/General/CustomHTTPSCertificates/).
- DNS configured for each Shelly device (for example `livingroom.shelly.example.com`) in a public DNS zone at a provider lego [supports](https://go-acme.github.io/lego/dns/index.html).

## Installation

Everything is located in one folder and will be linked to the needed folders (e.g. for systemd units). The project comes with three scripts to cleanly `install.sh`, `disable.sh` and `uninstall.sh` the service.

The program should be set up in `/opt`. It must not be set up under a home directory (e.g. `/home`, `/root` or `/run/user`) as the service runs with `ProtectHome=yes` and can't see those. The path also can't contain spaces as lego splits the hook command at spaces. There are safeguards implemented in `install.sh` that check both. 

### Quickstart

Clone the repository and then follow the instructions given by `install.sh` and the [Configuration](#configuration) section.

```sh
sudo git clone https://github.com/b-01/shelly-certs.git /opt/shelly-certs
cd /opt/shelly-certs
sudo ./install.sh
```

## Configuration

All commands below run in the tool folder (e.g. `/opt/shelly-certs`).

1. Set up global config:

   Configure ACME server, DNS provider, certificate options and more. Every setting is explained in the file.

   ```sh
   sudo cp config/shelly-certs.conf.example config/shelly-certs.conf
   sudoedit config/shelly-certs.conf
   ```

   **ACME Staging vs. Production**

   To test the application, you can start with the ACME staging server (it is the default in the example file), which has generous rate limits but issues certificates that are not in the trust stores of browsers and devices (so you will see warning messages!).

   How to switch from staging to production:
    
   1. Update the ACME_SERVER URL to the production URL and empty `DEVICE_CA_FILE`. lego keeps a separate account per server and creates the production account by itself.
      ```sh
      sudo sed -i \
        -e 's|^ACME_SERVER=.*|ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory|' \
        -e 's|^DEVICE_CA_FILE=.*|DEVICE_CA_FILE=|' \
        config/shelly-certs.conf
      ```
   2. Delete the staging certificates. They aren't due for renewal, so lego would otherwise keep them until they expire:
      ```sh
      sudo rm -r data/certificates
      ```
   3. Get a production certificate for every device and deploy it:
      ```sh
      sudo -u shelly-certs ./bin/shelly-certs run
      ```

2. Set up DNS credentials

   Configure the DNS provider lego should use to perform the DNS-01 challenges. Put the correct provider string as expected from lego in `DNS_PROVIDER` in `config/shelly-certs.conf`. Then put the variables that `lego dnshelp -c <code>` lists into `secrets/dns.env`.

   You can start from the provided example for Hetzner:

   ```sh
   sudo cp config/dns.env.example secrets/dns.env
   sudoedit secrets/hetzner.token            # the token on one line, nothing else
   ```

3. For staging only: 

   The device check after a deploy verifies the device's certificate, and your system doesn't trust staging certificates. Download the staging root certificates and point `DEVICE_CA_FILE` at them:

   ```sh
   curl -s https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem \
       https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x2.pem |
       sudo tee data/letsencrypt-staging-roots.pem >/dev/null
   ```

   Then set `DEVICE_CA_FILE=data/letsencrypt-staging-roots.pem`.

4. Finish installation

   Run the install script again to fix file/folder permissions, check the configuration and turn on the timer.

   ```sh
   sudo ./install.sh
   ```

5. Add your devices (next section).

### Add a device

An example device file is available, containing comments for the available values to set.

```sh
sudo cp config/devices.d/device.conf.example config/devices.d/livingroom.conf
sudoedit config/devices.d/livingroom.conf
sudoedit secrets/livingroom.password        # only if the device has a password
sudo ./install.sh                           # owner and mode of the password file, checks the config
```

If the new device file has errors, `install.sh` lists them and leaves the systemd units as they were, so the timer keeps running for the other devices.

The first name in `DOMAINS` is the certificate name and the name shelly-certs uses for HTTPS to the device. Two devices can't share them.

Configurable device reboot behaviour:
- `REBOOT=auto` immediately reboots the device after the upload and checks it serves the new certificate.
- `REBOOT=manual` only uploads the certificate and you are responsible for rebooting the device.

### Remove a device

Delete its config file (and its password file), then delete the certificate no device uses any more:

```sh
sudo rm config/devices.d/livingroom.conf secrets/livingroom.password
sudo -u shelly-certs ./bin/shelly-certs prune       # lists the unused certificates
sudo -u shelly-certs ./bin/shelly-certs prune --yes # deletes them
```

`prune` never revokes a certificate. It refuses to delete anything while a device config has errors.

## Disable / Uninstall

If you want to disable the systemd unit and timer, call `disable.sh`. It stops the timer, removes the links, but keeps config, secrets and certificates. Calling `install.sh` turns everything back on again.

If you intend to not use shelly-certs anymore, call `uninstall.sh` which also deletes config, secrets, data/ and the shelly-certs user. `uninstall.sh` asks before deleting (`--yes` skips the question). After uninstalling, you are left with the bare git repository.

## Daily use

The standard timer runs `shelly-certs run` every night at 03:30, plus a random delay of up to an hour. The start time can be configured by changing the `systemd/shelly-certs.timer` file and then running `./install.sh` again.

### Command reference

| Command | What it does |
|---|---|
| `run [--device NAME]... [--dry-run] [--force]` | For each device: lego requests a certificate, or renews it when it's due (`RENEW_DAYS`, or earlier if Let's Encrypt asks for it). The hook deploys new certificates. Then the device check deploys the local certificate if the device serves another one. Exits non-zero if any device failed; one failing device doesn't stop the others. |
| `run --dry-run` | Prints the lego commands and the RPC calls it would make, and doesn't change anything. |
| `run --force` | Renews even when not due. Let's Encrypt allows only 5 certificates for the same names per week. |
| `deploy NAME` | Uploads the current local certificate to one device. It doesn't contact Let's Encrypt. |
| `status` | Prints a table of devices: local expiry, days left, and `yes` / `no` / `pending-reboot` / `unreachable` for whether the device serves the local certificate, or `config-error`. |
| `list` | Prints the device names. |
| `validate` | Checks the config and secrets without network access. |
| `prune [--yes]` | Lists certificates no device uses; with `--yes` deletes them. |

#### Some additional useful commands

```sh
sudo systemctl start shelly-certs.service # run now, the same way the timer does
journalctl -u shelly-certs                # logs; lines about a device start with its name
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Tests

See [docs/testing.md](docs/testing.md).

## Not supported

- Wildcard certificates
- Finding devices on the network by itself
- Client certificates (mTLS)
- Gen1 devices
- Revoking certificates
