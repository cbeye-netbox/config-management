# 1. Install the config management plugin on NetBox Enterprise 2.5.0

These steps were run on a NetBox Enterprise 2.5.0 lab on 25 November 2026 (NetBox 4.7.3, four NetBox pods, two worker pods, preset Large). From "Deploy" to the last pod being ready took 25 minutes there. NetBox stays reachable during that time, because the pods restart one at a time. With a single NetBox pod, expect short interruptions.

You need: a shell on the NetBox Enterprise host with `sudo`, and the password of the admin console (port 30000).

## The short way

```sh
./install-plugin.sh --dry-run    # checks only, and prints the config text it would save
./install-plugin.sh
```

`install-plugin.sh` does every step of this document: it checks the image, copies the wheelhouse, adds the plugin to the Python override in the admin console, saves that as a new version, deploys it, and waits until the pods have restarted and the plugin answers. It asks for the admin console password, or takes `KOTS_PASSWORD` from `.env`.

It changes the override only when the text has the plain form `PLUGINS = [...]` with an optional plain `PLUGINS_CONFIG = {...}`. With any other text it stops and says so, and the steps below are done by hand.

Tested on the lab: the checks, the copy, the login to the admin console from inside the cluster, the edit of the override text, the waiting and the final check. Saving and deploying a version was tested with the same calls from outside the cluster. The script's own save and deploy did not run on the lab, because the plugin was already enabled there.

The rest of this document is the same work step by step.

## Before you start

1. Take a snapshot or backup the way you do before any change to this server. The plugin adds database tables.
2. Copy this folder to the host, then check the files:

   ```sh
   cd cfg2nb-kit
   sha256sum -c SHA256SUMS
   ```

   The commands below use `$K` for the `kubectl` of NetBox Enterprise. Set it once in your shell:

   ```sh
   K="sudo env KUBECONFIG=/var/lib/embedded-cluster/k0s/pki/admin.conf /var/lib/embedded-cluster/bin/kubectl -n kotsadm"
   ```

3. Check the image and the memory limits:

   ```sh
   ./check-image.sh
   ```

   It must print `same image as the one the wheelhouse was built and tested for`. If it names another image, stop: the wheelhouse holds compiled packages for Python 3.14 and the package versions of that one image.

   The NetBox pods must show a memory limit of `3000Mi` (preset Large). On the lab a NetBox pod used about 2.1 GiB half an hour after its start without the plugin, and 2.15 to 2.3 GiB with it. Pods that run for weeks grow towards the limit with or without the plugin (2.9 GiB after 14 days on the lab).

4. Check that `check-image.sh` says `no wheelhouse.tar.gz yet`. If one is there, it carries other custom plugins. NetBox Enterprise reads one archive only, so those plugins and this one must be built into one common wheelhouse first.

## Step 1: copy the wheelhouse into the media volume

```sh
./plugin-upload.sh
```

It copies `wheelhouse.tar.gz` to `/opt/netbox/netbox/media/wheelhouse.tar.gz` in a NetBox pod and compares the checksums. The copy restarts nothing. NetBox Enterprise installs the archive each time a pod starts.

The same by hand:

```sh
POD=$($K get pods -l netboxlabs.com/custom-plugins-upload=true -o jsonpath='{.items[0].metadata.name}')
$K cp wheelhouse.tar.gz kotsadm/$POD:/opt/netbox/netbox/media/wheelhouse.tar.gz -c netbox
$K exec $POD -c netbox -- sha256sum /opt/netbox/netbox/media/wheelhouse.tar.gz
```

Do not copy the archive into a pod's `/tmp`. That directory is memory-backed, so files there count against the memory limit of the container. On the lab a trial with the archive in `/tmp` got one NetBox container stopped and restarted by Kubernetes.

## Step 2: enable the plugin in the admin console

1. Open the admin console (`https://<host>:30000`), then "Config".
2. Find "NetBox Python Configuration Overrides" (under the advanced settings).
3. Add `'netbox_config_management'` to the end of your `PLUGINS` list, and add the `PLUGINS_CONFIG` block below. If you already have a `PLUGINS_CONFIG`, add the two entries to it. `python-override.txt` has the complete text for the override as it was on this server on 17 November.

   ```python
   PLUGINS = [
       # ... the plugins you already have ...
       'netbox_config_management',
   ]

   PLUGINS_CONFIG = {
       'netbox_config_management': {'collect_queue': 'high', 'push_queue': 'default'},
       'netbox_branching': {'exempt_models': ['netbox_config_management.*']},
   }
   ```

4. "Save config". The admin console creates a new version and runs its preflight checks.
5. Open "Version history" and "Deploy" the new version.

Why these two settings:

- `collect_queue` and `push_queue`: the plugin puts its jobs on two queues of its own. The NetBox Enterprise worker serves only NetBox's three queues (`high`, `default`, `low`), and it has no setting for more. The patch in this wheelhouse lets the plugin use one of those three. `high` is the right one for evaluations: NetBox itself leaves it empty, while `default` fills up with search index jobs after every change. On the lab an evaluation on `default` waited four minutes behind them after an import.
- `netbox_branching`: the plugin's tables are not branch-aware. Its documentation asks for this exemption where the branching plugin is on, which is the case on NetBox Enterprise.

## Step 3: wait for the restarts

Watch the pods:

```sh
watch -n 10 "$K get pods | grep -E 'netbox-netbox|migrate'"
```

What you see, in this order:

1. Two migration jobs (`netbox-netbox-migrate-p1-...`, then `-p2-...`). The first applies `netbox_config_management.0001_initial`.
2. The NetBox pods restart one at a time. Each takes about three minutes to become ready.
3. A second pair of migration jobs and a second round of restarts follow by themselves. NetBox Enterprise does this once it sees that a plugin from the wheelhouse is in use.
4. The two worker pods restart last. Evaluations only work after that.

It is done when every `netbox-netbox-...` pod shows `2/2 Running` and none is older than the deployment.

## Step 4: check

```sh
./cfg2nb.sh ncm status
```

It asks for a NetBox API token (see `2-IMPORT.md`) and must print `plugin API reachable` followed by the endpoints, and at least one worker on the queue `high`:

```
plugin API reachable: http://netbox-netbox.kotsadm.svc.cluster.local/api/plugins/config-management/
  config-revisions
  ...
queue high: 2 workers, 0 jobs waiting
```

In the web UI: the menu has "Config Management", and every device has the tabs "Config History" and "Compliance".

## If something goes wrong

- A new NetBox pod does not become ready: read its log with `$K logs <pod> -c netbox | tail -50`. The start script names a plugin it cannot import. The old pods keep serving meanwhile, because the pods are replaced one at a time.
- To go back: remove `'netbox_config_management'` from `PLUGINS` and its entry from `PLUGINS_CONFIG`, save and deploy. This was not run on the lab. The plugin's tables stay in the database. While the plugin is off, a device that has rows there (config revisions, a drift report) cannot be deleted, so run `./cfg2nb.sh remove` (see `2-IMPORT.md`) before you turn the plugin off. The wheelhouse can stay in the media volume or be deleted (`$K exec $POD -c netbox -- rm /opt/netbox/netbox/media/wheelhouse.tar.gz`).
- An evaluation stays pending: check `./cfg2nb.sh ncm status`. `queue high: 0 workers` means the worker pods have not restarted yet or the queue settings are missing.

## What is in the wheelhouse

- `netbox-config-management` 0.0.0, commit `0303b78` of the private repository, with one patch: `collect_queue` and `push_queue` may name one of NetBox's own queues.
- 43 more packages. 33 of them are in the NetBox image already, in the same versions, so nothing in the image is replaced by another version. 10 are new: `napalm`, `hier-config`, `netutils`, `ncclient`, `junos-eznc`, `pyeapi`, `pyparsing`, `transitions`, `ttp-templates`, `yamlloader`.
- Installed size in each pod: 112 MB.

While installing, `pip` prints two lines about `netbox-validity` wanting `simpleeval==1.0.7` and `textfsm<2`. The image itself ships `simpleeval 1.0.8` and `textfsm 2.1.0`, so this message describes the image as delivered and the wheelhouse does not change it.
