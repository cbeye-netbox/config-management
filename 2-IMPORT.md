# 2. Import the switch config into NetBox

`cfg2nb` reads the output of `show running-config` of a Cisco IOS XE device and builds that device in NetBox: objects where NetBox has a model, and a config template that prints the config back from them. It then asks NetBox to render the config and compares the result with the file, line by line.

Tested on 25 November 2026 against NetBox Enterprise 2.5.0 (NetBox 4.7.3) with the config of HCLAB455: 172 objects, 2,130 of 2,130 lines rendered identically, and a second run changed nothing.

## Run it

You need a NetBox API token with write access. In NetBox: your user menu (top right), "API Tokens", "Add a token", leave "Write enabled" on. Copy the token when it is shown: NetBox shows it once.

On the NetBox Enterprise host, in the kit folder:

```sh
./cfg2nb.sh import /path/to/HCLAB455_show_run.cfg
```

It asks for the token and does the rest. To skip the question, put the token into a file `.env` in the folder you run it from (`chmod 600 .env`), or into the environment:

```sh
NETBOX_TOKEN='nbt_...'
```

What it prints (from the lab run):

```
config: HCLAB455_show_run.cfg, device HCLAB455, 2130 lines, 2044 modelled in 28 features, 1 carried as text, 85 separators
NetBox: http://netbox-netbox.kotsadm.svc.cluster.local, version 4.7.3
device: HCLAB455 is new, site Config drift lab
plan: 172 objects; as objects: acls, interfaces, lines, logging, ntp, snmp, vlans; in the config context: aaa, aliases, ...
  ... 25 of 172 objects
  ...
load: 169 created, 0 updated, 0 deleted, 3 unchanged
verify: NetBox renders the config back, 2130 lines identical
device page: .../dcim/devices/2136/
drift detection: platform profile of cisco-ios-xe with the ACL section and the secret rules: set up
drift detection: remediation policy, review rule and managed scope "Config drift check" with this device: set up
drift detection: running config from the imported config: stored as revision 1
HCLAB455: compliant, score 100, engine hier
```

The page links it prints start with `https://<your NetBox address>` when it runs in the pod, because it does not know the address your browser uses. Add `NETBOX_PUBLIC_URL='https://netbox.example.com'` to `.env` to get complete links.

The load takes about three minutes for this device. The last four lines appear only when the plugin from `1-INSTALL-PLUGIN.md` is installed. Without it the import ends after `verify`.

## What it configures in the plugin

The import sets the plugin up completely, so nothing is created by hand:

| In the plugin | What the import creates | Why |
|---|---|---|
| Platform profile for "Cisco IOS XE" | the plugin's IOS XE preset: five config sections and 16 rules | how configs of this platform are read and compared |
| Config section `acl` | matches `ip access-list` and `access-list`, severity high, weight 2 | the preset has no section for ACLs, so ACL lines would be listed but not scored |
| Three normalization rules | `snmp-server community` lines are left out, community strings on `snmp-server host` lines and type 7 secrets are compared by presence | the config in NetBox holds stand-ins, a device holds the real secrets |
| Remediation policy "Config drift: one review" | one approval needed, nothing approved automatically, the user who runs the import named as reviewer | the plugin needs a policy with a rule. It becomes the default policy if there is none |
| Managed scope "Config drift check" | devices with the tag "Config drift check", collection interval 0, no automatic requests | the device shows as managed. Interval 0 means NetBox never logs in to it on a schedule |
| The tag "Config drift check" on the device | | puts the device into the scope |

Nothing reaches a device: the plugin's `push_enabled` setting is off, which is its default.

Running it again is safe. It compares each object with NetBox and writes only what differs, so a second run reports `0 created, 0 updated`.

## Where it runs

`cfg2nb.sh` decides by the machine it is on:

- On a NetBox Enterprise host it copies `cfg2nb.pyz` and the config file into a NetBox worker pod and runs it there. The pod has Python 3.14 and reaches NetBox inside the cluster. The host needs no Python and no DNS name for NetBox. The work directory in the pod is removed afterwards.
- Anywhere else it uses the Python of that machine (3.8 or newer) and asks for the NetBox URL as well. From a laptop: `python3 cfg2nb.pyz import FILE --url https://netbox.example.com`.

`./cfg2nb.sh --in-pod ...` and `./cfg2nb.sh --local ...` force one or the other.

## What it creates

For HCLAB455:

| In NetBox | Count | From the config |
|---|---|---|
| Device, with site, role, platform, config template | 1 each | `hostname`, `switch 1 provision` |
| Interfaces, with mode, VLANs, VRF, description, enabled | 57 | `interface` blocks |
| Port profiles (Custom Objects), linked from each interface | 5 | the other lines of the interface blocks, shared by the interfaces that have the same ones |
| VLANs, VRF, interface address | 2, 1, 1 | `vlan`, `vrf forwarding`, `ip address` |
| Access lists, assigned to the device (ACL plugin) | 5 | `ip access-list standard` 93, 94, 95, 98, 99 |
| ACL rules with their sequence numbers | 54 | the entries |
| Prefixes and addresses the rules point at | 19, 3 | the sources of the entries |
| Line configs (Custom Objects) | 3 | `line con 0`, `line vty 0 4`, `line vty 5 32`, with `transport input` as a field |
| SNMP communities and trap hosts, NTP servers, logging hosts (Custom Objects) | 3, 3, 2, 1 | `snmp-server`, `ntp server`, `logging host` |

The other 21 feature families (AAA, TACACS and RADIUS servers, QoS, banners, PKI and others) are stored as structured data in the device's config context under the key `cfg2nb`, and the template prints them from there. One line that no feature models (`end`) is carried as text.

What it leaves alone:

- A site, role, platform, manufacturer or device type that NetBox already has is used as it is, found by slug or by name. A device type is also found by its part number, so the "Catalyst 9300L-48T-4X" of the device type library is used for `C9300L-48T-4X`.
- A prefix or address that NetBox already has is used as it is.
- A new device goes to the site "Config drift lab" unless `--site` names another. If NetBox already has a device of that name, it stays at its site, with its role and type. It gets the config template and the `cfg2nb` key in its config context, and keeps its other context keys.

Everything the import creates carries the tag `cfg2nb`.

## Options

```sh
./cfg2nb.sh import FILE --dry-run          # show what would be created, write nothing
./cfg2nb.sh import FILE --site "Campus lab" # put a new device at this site (also --role, --platform, --device-type)
./cfg2nb.sh import FILE --no-drift-setup   # stop after verify, even when the plugin is installed
./cfg2nb.sh import FILE -v                 # list every object
./cfg2nb.sh plan FILE                      # the objects the config becomes, without NetBox
./cfg2nb.sh check FILE                     # offline: does the config print back identically
```

## Take it out again

```sh
./cfg2nb.sh remove FILE            # the device and what was created for it
./cfg2nb.sh remove FILE --purge    # also the Custom Objects types, the custom field and the tag, once nothing uses them
./cfg2nb.sh remove FILE --dry-run  # show what would go
```

`remove` deletes only objects that carry the tag `cfg2nb`. What was in NetBox before the import stays, and so does anything another object still uses. It lists what it kept and why. On the lab it deleted 169 objects and kept three: the device type and the manufacturer, which were there before, and the custom field, which `--purge` removes.

## Secrets

The config file holds secrets (enable secret, user passwords, TACACS and RADIUS keys, SNMP communities). `cfg2nb` replaces each one with a stand-in (`cfg2nb-standin-01`, `-02`, ...) before anything goes to NetBox, so NetBox never stores them. It refuses to load when a line that no feature models looks like it holds a secret.

The file as received has `<secret>` in place of most secrets, and three community strings in clear text on the `snmp-server host` lines. The stand-ins cover both.

## The input file

- It must be the output of `show running-config` of a Cisco IOS XE device. Lines before the config starts and the prompt at the end are ignored.
- The file as received has lost the single leading space of indented lines. `cfg2nb` restores it from the block structure of IOS XE. `./cfg2nb.sh restore FILE -o restored.cfg` writes the restored text.
- A line or block that `cfg2nb` does not model is never dropped. It is carried as text and printed back as it was. `./cfg2nb.sh check FILE --unclaimed` lists such lines.

## If something goes wrong

- `error: ... -> 403`: the token has no write access, or the user lacks permissions. A superuser token avoids permission questions.
- `note: <feature> stays in the config context: this NetBox does not have the plugin ...`: the ACL plugin or the Custom Objects plugin is not enabled. The import still works and keeps that feature as data in the config context.
- `verify: NetBox renders something else`: the lines that differ are printed. Send them along with the output of `./cfg2nb.sh --version`.
- `evaluation job ... is waiting for a worker`: NetBox is working off other jobs. The import waits up to 15 minutes. If it gives up, run `./cfg2nb.sh ncm evaluate --device HCLAB455` later.
