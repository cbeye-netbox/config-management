# 3. The demo: drift on HCLAB455

What it shows: NetBox holds the standard for the switch. A config that arrives from the device is compared with it, and NetBox lists what differs, by section and severity. The four differences are the ones asked for:

| Difference | In the device config | Section, severity |
|---|---|---|
| Extra entry in ACL 93 | `155 permit 10.99.99.0 0.0.0.255` added | acl, high |
| ACL 94 missing | the whole list is gone | acl, high |
| Changed entry in ACL 95 | entry 40 points at another network | acl, high |
| Telnet enabled | `transport input telnet ssh` on `line vty 0 4` and `line vty 5 32` | access, critical |

Run on the lab on 25 November 2026: the report came back in six seconds as drifted, score 94, severity critical.

The config file as received does not have Telnet enabled: both vty blocks say `transport input ssh`. So Telnet is one of the differences the demo puts in, like the three ACL changes.

## Before the audience arrives

1. The plugin is installed (`1-INSTALL-PLUGIN.md`) and the config is imported (`2-IMPORT.md`). The import ends with `HCLAB455: compliant, score 100`.
2. Have two windows ready: a shell in the kit folder on the NetBox host, and NetBox in a browser on the device HCLAB455.
3. Put the API token into `.env` in the kit folder, so no command stops to ask for it.

## Part 1: the standard is in NetBox

On the device page of HCLAB455:

- "Access Lists" tab: the five ACLs. Open 93: 16 rules with sequence number, action and source prefix. These are objects of the ACL plugin, and the source prefixes are IPAM prefixes.
- "Custom Objects" tab: the line configs. Open `vty 0 4`: the field "Transport input" holds `ssh`. This field is where "no Telnet" is kept.
- "Render Config" tab: the config NetBox prints from these objects, 2,130 lines. They are the lines of the file, with stand-ins where the file has secrets.
- "Compliance" tab: Compliant, score 100.

## Part 2: a changed config arrives

In the shell:

```sh
./cfg2nb.sh drift HCLAB455_show_run.cfg --push
```

This builds the switch config with the four differences, stores it in NetBox as the newest running config of HCLAB455 and waits for the evaluation. It prints the report:

```
drift: ACL 93: added entry 155 permit 10.99.99.0/24
drift: ACL 94: removed
drift: ACL 95: entry 40 changed from <network> to <the next network>
drift: vty lines: transport input now allows telnet (2 blocks)
HCLAB455: running config stored as revision 2
HCLAB455: drifted, score 94, severity critical, engine hier
  access: drifted (critical, weight 3), 2 missing, 2 extra
    missing  line vty 0 4 / transport input ssh
    missing  line vty 5 32 / transport input ssh
    extra    line vty 0 4 / transport input telnet ssh
    extra    line vty 5 32 / transport input telnet ssh
  acl: drifted (high, weight 2), 15 missing, 2 extra
    missing  ip access-list standard 94
    ... (its 13 entries)
    missing  ip access-list standard 95 / 40 permit <network>
    extra    ip access-list standard 93 / 155 permit 10.99.99.0 0.0.0.255
    extra    ip access-list standard 95 / 40 permit <the next network>
  interfaces: compliant
  ...
```

In the browser, reload the "Compliance" tab: Drifted, Critical, score 94. The table lists per section what is missing from the device and what is extra on it. "Missing" is in the standard and not on the device. "Extra" is on the device and not in the standard.

The "Config History" tab lists the stored configs. Select two and compare them to see the text difference.

To show one difference at a time, leave the others out:

```sh
./cfg2nb.sh drift HCLAB455_show_run.cfg --push --no-missing --no-changed --no-telnet   # only the extra entry in 93
./cfg2nb.sh drift HCLAB455_show_run.cfg --push --no-extra --no-missing --no-changed    # only Telnet
```

## Part 3: back to compliant

```sh
./cfg2nb.sh render HCLAB455_show_run.cfg --push
```

This stores the unchanged config as the newest running config. The report says `compliant, score 100`.

## Variation: change the standard in NetBox

The comparison works in both directions. Change the standard, and the device no longer matches it:

1. In NetBox open the line config `vty 0 4` (Custom Objects) and add `telnet` to "Transport input", or open ACL 93 and delete a rule.
2. On the device's "Compliance" tab press "Evaluate", or run `./cfg2nb.sh ncm evaluate --device HCLAB455`.
3. The report shows the device as drifted again. This time the device did not change: the standard did.

Undo it by running the import again: `./cfg2nb.sh import HCLAB455_show_run.cfg` sets every object back to what the file says.

## How a backup tool posts a config

The demo stores configs with `cfg2nb`. A backup tool does the same with one REST call. The body has the NetBox id of the device and the config text:

```
POST /api/plugins/config-management/config-revisions/
Authorization: Bearer <token>
Content-Type: application/json

{"device": 2136, "content": "<the output of show running-config>"}
```

NetBox answers 201 for a new config and 200 when the text is the same as the newest stored one. A new config starts an evaluation by itself. No device login is stored in NetBox for this.

Two things the posted text needs:

- The indentation as the device prints it. The comparison reads the config as a tree, and a config without indentation compares as all different. `./cfg2nb.sh restore FILE -o restored.cfg` repairs a file that lost it.
- Secrets may differ from the stand-ins in NetBox. The platform profile that the import sets up compares secret-bearing lines without their secret, and leaves `snmp-server community` lines out of the comparison.

## Optional: NetBox reads the device itself

The steps above need no device login in NetBox: a config is posted over REST. NetBox can also log in to a device and read the running config itself. In the "Config History" tab such a config has the source "Live pull" and a posted one "REST API".

Run on the lab on 25 November 2026 with an IOS XE 17.16 switch: after a change on the switch, NetBox logged in, read the config and reported the drift, 7 seconds in all. Not run against a Catalyst 9300 with 17.12.

What it needs:

- A device login that may run `show running-config` and `show startup-config` (privilege 15, or an enable secret). NetBox reads with it. It writes nothing to a device: pushing is off by default.
- SSH from the NetBox worker pods to the device's primary IP address in NetBox.
- The login in the plugin's settings. That is a config change in the admin console, so the NetBox pods restart once more (17 minutes on the lab).

Two commands:

```sh
./cfg2nb.sh nbe add-login --set lab                              # asks for the admin console password, the device user name and its password
./cfg2nb.sh ncm scope --device HCLAB455 --credential-set lab     # after the restart
```

The first stores the login under the name `lab` and deploys the change. The password is asked for on the terminal and never shown. `./cfg2nb.sh nbe show-override` prints the settings with passwords hidden.

The second puts HCLAB455 into a second managed scope, "Config drift check: live pull (lab)", which names that login. NetBox logs in only to devices in that scope. Every other device stays in the scope without a login. With `--interval 1` NetBox also reads the devices of that scope by itself, every 5 minutes: that is how often the plugin checks which devices were last read longer ago than the interval. Without it NetBox reads them only when asked.

Then, after a change on the device:

```sh
./cfg2nb.sh ncm collect --device HCLAB455
```

or the "Collect" button on the device's "Compliance" tab ("Collect now" on "Config History"). NetBox logs in, stores the config if it differs from the newest one and evaluates it.

To do the restart only once, store the login before the plugin is installed: `./cfg2nb.sh nbe add-login --set lab --no-deploy`, then `./install-plugin.sh`. The installer builds on the saved version, so both changes go out together. This order is covered by the script's tests and was not run on a server.

To stop it: `./cfg2nb.sh ncm scope --device HCLAB455 --no-login` takes the device out of that scope again.

One thing to know: do not delete the tags "Config drift: live pull (lab)" and "Config drift: live pull guard" by hand. They are the filter of that scope, and the plugin treats a scope without a filter as "every device".

## What to say if asked

| Question | Answer |
|---|---|
| Is this a product feature? | The plugin is alpha: version 0.0.0, no release yet. What is shown is what it does today. |
| What does the score mean? | Each section has a weight, and only sections in "enforce" mode count. The preset for IOS XE has five sections. The import adds a sixth for ACLs, because the preset has none and ACL lines would otherwise not be scored. |
| What is the Remediation box with "Open remediation request"? | The plugin can plan the commands that bring the device back to the standard (25 commands in this case) and put them through a review. Nothing reaches a device: pushing is off by default (`push_enabled`), and the demo does not turn it on. |
| What does the Collect button do? | It makes NetBox log in to the device and read its config. That needs a device login in the plugin's settings, which the demo does not set unless you follow "Optional: NetBox reads the device itself" above. Without one the collection fails before any connection is opened and changes nothing. |
| Can I write a rule such as "no Telnet"? | There is no rule language. The standard is the config NetBox renders, so "no Telnet" is the line `transport input ssh` in each vty block. |

## If the report does not come

- `evaluation job ... is waiting for a worker`: NetBox is busy with other jobs. Wait, or check `./cfg2nb.sh ncm status`: the queue `high` must have at least one worker.
- `./cfg2nb.sh ncm report --device HCLAB455` prints the last stored report again.
- `./cfg2nb.sh ncm compare --device HCLAB455` compares inside the web request and needs no worker. It prints the same differences and does not update the Compliance tab.
