# Config drift demo kit for NetBox Enterprise 2.5.0

This folder holds what is needed to show config drift detection on a NetBox Enterprise 2.5.0 server that cannot download anything. Copy the whole folder to the server.

Built and tested on 25 November 2026 on a NetBox Enterprise 2.5.0 lab: NetBox 4.7.3, image `nbe-core:4.7.3_2.5.0-10212.g4f1cf7560`, Ubuntu 24.04 host. Not yet run on RHEL 8. The host only needs `bash`, `sudo` and the `kubectl` that NetBox Enterprise installs.

## What you do, in order

| Step | Command | Document | Time on the lab |
|---|---|---|---|
| 1. Install the config management plugin | `./install-plugin.sh` | `1-INSTALL-PLUGIN.md` | 30 to 45 minutes, most of it waiting for restarts |
| 2. Import the switch config into NetBox and configure the plugin | `./cfg2nb.sh import FILE` | `2-IMPORT.md` | 5 minutes |
| 3. Show the drift | `./cfg2nb.sh drift FILE --push` | `3-DEMO.md` | 10 minutes |

Nothing is clicked by hand. Step 1 asks for the admin console password, step 2 for a NetBox API token.

Step 2 works without step 1. It then builds the device in NetBox and stops before the drift part.

Optional, and off unless you turn it on: NetBox can log in to a device and read its config itself (`./cfg2nb.sh nbe add-login`, `./cfg2nb.sh ncm scope --credential-set`, `./cfg2nb.sh ncm collect`). `3-DEMO.md` has the steps. Without it no device login is stored in NetBox.

## Files

| File | What it is |
|---|---|
| `cfg2nb.pyz` | The import script as one file. Needs Python 3.8 or newer and nothing else. |
| `cfg2nb.sh` | Runs `cfg2nb.pyz`. On a NetBox Enterprise host it runs it inside a NetBox worker pod, so the host needs no Python. |
| `wheelhouse.tar.gz` | The plugin `netbox-config-management` and its Python packages for the image named above (44 packages, 23 MB). |
| `install-plugin.sh` | Installs the plugin in one go: the two checks below, then the admin console change, then it waits for the restarts. |
| `check-image.sh` | Checks that the server runs that image and shows the memory limits. Changes nothing. |
| `plugin-upload.sh` | Copies `wheelhouse.tar.gz` into the media volume and compares checksums. |
| `nbe-common.sh` | Used by the scripts above. |
| `python-override.txt` | The text for "NetBox Python Configuration Overrides" in the admin console. |
| `image-packages.txt` | Package versions of the image the wheelhouse was built against. |
| `WHEELHOUSE-INFO.txt` | Plugin commit, patch and versions inside the wheelhouse. |
| `SHA256SUMS` | Checksums of the files in this folder. Check with `sha256sum -c SHA256SUMS`. |

The switch config (`HCLAB455_show_run.cfg`) is not in the kit. It is the customer's file and stays with the customer.

## What changes on the server

- The plugin and its packages are installed into the NetBox pods at each pod start, from the media volume. Nothing is written into the image.
- One database migration adds the plugin's tables (13 models).
- The admin console gets a new config version with the plugin in `PLUGINS`.
- The import adds one device with its interfaces, ACLs, VLANs and addresses, six Custom Objects types, one custom field on interfaces (`port_profile`) and one config template. Everything it creates carries the tag `cfg2nb`. `./cfg2nb.sh remove` deletes it again.
- The import also configures the plugin: a platform profile for IOS XE with a section for ACLs and rules for secret-bearing lines, a remediation policy with one review rule, and a managed scope that holds the imported device and never logs in to it.

## Limits you should know before the demo

- The plugin is alpha (version 0.0.0, commit `0303b78` of 23 November 2026). It has no release yet and its database tables can still change. A later update can mean dropping and rebuilding its tables.
- The wheelhouse carries one patch to the plugin (`WHEELHOUSE-INFO.txt`). Without it the plugin's jobs never run on NetBox Enterprise, because the Enterprise worker serves only NetBox's own three queues.
- The plugin compares text. "Telnet must be off" is in NetBox as `transport input ssh` on each vty block, and the plugin reports a device that has another line there.
- Use of the plugin outside NetBox Labs needs written permission from NetBox Labs (its `LICENSE.md`).
