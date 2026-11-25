#!/usr/bin/env bash
# Install the config management plugin on NetBox Enterprise 2.5.0 in one go.
#
#   ./install-plugin.sh
#
# It does what 1-INSTALL-PLUGIN.md describes step by step:
#   1. checks that this server runs the image the wheelhouse was built for
#   2. copies wheelhouse.tar.gz into the media volume
#   3. adds the plugin to "NetBox Python Configuration Overrides" in the admin console,
#      saves that as a new version and deploys it (asks for the admin console password,
#      or takes KOTS_PASSWORD from the environment or from .env)
#   4. waits until NetBox Enterprise has run the migrations and restarted its pods
#   5. checks that the plugin answers
#
# Step 3 changes the NetBox configuration and restarts NetBox. NetBox Enterprise
# restarts the pods one at a time, twice on a first enable. On the lab that took 25
# minutes with four NetBox pods. With one NetBox pod, NetBox is unreachable for a few
# minutes in each round.
#
#   ./install-plugin.sh --dry-run    steps 1 and 2 are checked only, step 3 prints the new
#                                    override text and saves nothing
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/nbe-common.sh"

dry_run=0
[ "${1:-}" = "--dry-run" ] && dry_run=1

echo "== 1. the image and the memory limits"
"$here/check-image.sh"

echo
echo "== 2. the wheelhouse in the media volume"
if [ "$dry_run" = 1 ]; then
    echo "dry run: not copied"
else
    "$here/plugin-upload.sh"
fi

echo
echo "== 3. the plugin in the admin console"
if [ "$dry_run" = 1 ]; then
    "$here/cfg2nb.sh" --in-pod nbe enable-plugin --dry-run
    exit 0
fi
enable_log="$(mktemp)"
"$here/cfg2nb.sh" --in-pod nbe enable-plugin | tee "$enable_log"
if grep -q "nothing to do" "$enable_log"; then
    rm -f "$enable_log"
    echo
    echo "== 4. nothing was deployed, so there is nothing to wait for"
    echo "== 5. the plugin is enabled already"
    echo "Next: ./cfg2nb.sh import <the show running-config file>   (2-IMPORT.md)"
    exit 0
fi
rm -f "$enable_log"

echo
echo "== 4. waiting for the migrations and the restarts (this takes a while)"
state() {
    # generation/observed updated/ready/replicas/unavailable of one deployment
    k get deploy "$1" -o jsonpath='{.metadata.generation}/{.status.observedGeneration} {.status.updatedReplicas}/{.status.readyReplicas}/{.status.replicas}/{.status.unavailableReplicas}' 2>/dev/null || true
}
settled() {
    # true when the deployment has rolled out its newest template completely
    local generations counts
    read -r generations counts <<<"$(state "$1")"
    [ -n "$generations" ] || return 1
    [ "${generations%/*}" = "${generations#*/}" ] || return 1
    local updated ready replicas unavailable
    IFS=/ read -r updated ready replicas unavailable <<<"$counts"
    [ -n "$replicas" ] && [ "$updated" = "$replicas" ] && [ "$ready" = "$replicas" ] && [ -z "$unavailable" ]
}
migrating() {
    k get jobs -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -q migrate
}
plugin_answers() {
    # Without a token NetBox answers 403 for a plugin that is there and 404 for one that is not.
    local pod code
    pod="$(worker_pod)"
    [ -n "$pod" ] || return 1
    code="$(k exec "$pod" -c netbox-worker -- /opt/netbox/venv/bin/python -c '
import sys, urllib.request, urllib.error
url = "http://netbox-netbox.'"$namespace"'.svc.cluster.local/api/plugins/config-management/"
request = urllib.request.Request(url, headers={"X-Forwarded-Proto": "https", "Accept": "application/json"})
try:
    print(urllib.request.urlopen(request, timeout=15).status)
except urllib.error.HTTPError as error:
    print(error.code)
except Exception:
    print(0)
' 2>/dev/null || echo 0)"
    [ "$code" = 200 ] || [ "$code" = 401 ] || [ "$code" = 403 ]
}

started="$(date +%s)"
quiet=0
while :; do
    sleep 20
    elapsed=$(( $(date +%s) - started ))
    if settled netbox-netbox && settled netbox-netbox-worker && ! migrating; then
        quiet=$((quiet + 20))
    else
        quiet=0
    fi
    if [ $((elapsed % 60)) -lt 20 ]; then
        printf '%s  NetBox pods %s, workers %s, quiet for %ss\n' "$(date +%H:%M:%S)" \
            "$(state netbox-netbox | cut -d' ' -f2)" "$(state netbox-netbox-worker | cut -d' ' -f2)" "$quiet"
    fi
    # Four quiet minutes: a second round of restarts starts sooner than that when one is due.
    if [ "$quiet" -ge 240 ] && [ "$elapsed" -ge 300 ]; then
        if plugin_answers; then
            break
        fi
        echo "the pods are settled but the plugin does not answer yet: waiting on"
        quiet=0
    fi
    if [ "$elapsed" -gt 5400 ]; then
        echo "No settled state after 90 minutes. Look at the pods: ${kubectl[*]} -n $namespace get pods" >&2
        exit 1
    fi
done

echo
echo "== 5. done after $(( ($(date +%s) - started) / 60 )) minutes: the plugin answers"
echo "Next: ./cfg2nb.sh import <the show running-config file>   (2-IMPORT.md)"
