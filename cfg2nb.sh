#!/usr/bin/env bash
# Run cfg2nb.pyz on a server where nothing can be installed.
#
#   ./cfg2nb.sh import HCLAB455_show_run.cfg
#
# On a NetBox Enterprise host (the embedded cluster's kubectl is there) cfg2nb runs
# inside a NetBox worker pod: that pod has Python 3.14 and reaches NetBox inside the
# cluster, so the host needs no Python, no DNS name for NetBox and no certificate.
# Anywhere else it runs with the Python of this machine (3.8 or newer) and talks to
# NetBox over its URL.
#
#   ./cfg2nb.sh --in-pod ...   run in the pod, whatever this host has
#   ./cfg2nb.sh --local ...    run with this host's Python, whatever this host is
#
# In the pod:
# - Files named on the command line are copied into the pod. Files the command writes
#   (-o FILE) are copied back to the path you gave.
# - The API token is asked for, or taken from NETBOX_TOKEN or from .env in this directory.
# - The work directory in the pod (/tmp/cfg2nb.<number>, a few hundred KiB) is removed
#   afterwards.
#
# Environment:
#   KUBECTL        kubectl command (default: the one of the embedded cluster, with sudo
#                  when not root; else kubectl from PATH)
#   NBE_NAMESPACE  namespace of NetBox Enterprise (default kotsadm)
#   NBE_POD        pod to run in (default: the first running NetBox worker pod)
#   CFG2NB_POD_URL NetBox URL as seen from that pod
#                  (default http://netbox-netbox.<namespace>.svc.cluster.local)
#   NETBOX_PUBLIC_URL  the address of NetBox in a browser, for the page links that are
#                  printed (environment or .env; without it a placeholder is printed)
#   KOTS_PASSWORD  the admin console password, for "cfg2nb.sh nbe ..." (environment or
#                  .env; without it the command asks)
#   CFG2NB_CONSOLE_URL  the admin console as seen from the pod
#                  (default http://kotsadm.<namespace>.svc.cluster.local:3000)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pyz="$here/cfg2nb.pyz"
[ -f "$pyz" ] || { echo "cfg2nb.pyz not found next to this script ($here)" >&2; exit 2; }

embedded=/var/lib/embedded-cluster/bin/kubectl
admin_conf=/var/lib/embedded-cluster/k0s/pki/admin.conf

mode=auto
case "${1:-}" in
    --in-pod) mode=pod; shift ;;
    --local) mode=local; shift ;;
esac
if [ "$mode" = auto ]; then
    if [ -n "${KUBECTL:-}" ] || [ -x "$embedded" ]; then mode=pod; else mode=local; fi
fi

find_python() {
    local candidate
    for candidate in python3 python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
        if command -v "$candidate" >/dev/null 2>&1 &&
            "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if [ "$mode" = local ]; then
    if python="$(find_python)"; then
        exec "$python" "$pyz" "$@"
    fi
    echo "No Python 3.8 or newer on this host. On a NetBox Enterprise host run: $0 --in-pod ..." >&2
    exit 2
fi

# --- inside a NetBox worker pod -----------------------------------------------------

namespace="${NBE_NAMESPACE:-kotsadm}"
if [ -n "${KUBECTL:-}" ]; then
    read -r -a kubectl <<<"$KUBECTL"
elif [ -x "$embedded" ]; then
    kubectl=(env "KUBECONFIG=$admin_conf" "$embedded")
    [ "$(id -u)" = 0 ] || kubectl=(sudo "${kubectl[@]}")
elif command -v kubectl >/dev/null 2>&1; then
    kubectl=(kubectl)
else
    echo "No kubectl found. Set KUBECTL, or use --local on a machine with Python 3.8 or newer." >&2
    exit 2
fi
k() { "${kubectl[@]}" -n "$namespace" "$@"; }

# The worker pod, not a web pod: it has the same Python and far more free memory.
pod="${NBE_POD:-}"
if [ -z "$pod" ]; then
    pod="$(k get pods -l netboxlabs.com/component=netbox-worker --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
[ -n "$pod" ] || { echo "no running NetBox worker pod found in namespace $namespace (label netboxlabs.com/component=netbox-worker)" >&2; exit 2; }
container="$(k get pod "$pod" -o jsonpath='{.spec.containers[0].name}')"

# /tmp in the pod is memory-backed: only these small files go there, never a wheelhouse.
work="/tmp/cfg2nb.$$"
px() { k exec -i "$pod" -c "$container" -- "$@"; }
cleanup() { px rm -rf "$work" >/dev/null 2>&1 || true; }
trap cleanup EXIT
px mkdir -p "$work"
px sh -c "cat > $work/cfg2nb.pyz" <"$pyz"

# Connection settings for the run in the pod. The token never appears on a command line.
load_env_value() {
    # value of KEY from the environment, else from .env in the current directory
    local key="$1" value="${!1:-}"
    if [ -z "$value" ] && [ -f .env ]; then
        value="$(sed -n "s/^$key=//p" .env | tail -1 | sed -e "s/^['\"]//" -e "s/['\"]\$//")"
    fi
    printf '%s' "$value"
}
token="$(load_env_value NETBOX_TOKEN)"
public="$(load_env_value NETBOX_PUBLIC_URL)"
console_password="$(load_env_value KOTS_PASSWORD)"
{
    [ -z "$public" ] || printf "NETBOX_PUBLIC_URL='%s'\n" "$public"
    # The admin console, for "cfg2nb nbe ...": reached inside the cluster as well.
    printf "KOTS_URL='%s'\n" "${CFG2NB_CONSOLE_URL:-http://kotsadm.$namespace.svc.cluster.local:3000}"
    [ -z "$console_password" ] || printf "KOTS_PASSWORD='%s'\n" "$console_password"
    printf "NETBOX_URL='%s'\n" "${CFG2NB_POD_URL:-http://netbox-netbox.$namespace.svc.cluster.local}"
    printf "NETBOX_FORWARDED_PROTO='https'\n"
    printf "NETBOX_NO_PROXY='1'\n"
    [ -z "$token" ] || printf "NETBOX_TOKEN='%s'\n" "$token"
} | px sh -c "umask 077; cat > $work/.env"

# Copy input files in, and remember where output files belong.
args=()
uploaded=()
outputs_remote=()
outputs_local=()
expect_output=0
for arg in "$@"; do
    if [ "$expect_output" = 1 ]; then
        expect_output=0
        if [ "$arg" != "-" ]; then
            outputs_remote+=("$(basename "$arg")")
            outputs_local+=("$arg")
            args+=("$(basename "$arg")")
            continue
        fi
    elif [ "$arg" = "-o" ] || [ "$arg" = "--output" ]; then
        expect_output=1
    elif [ -f "$arg" ]; then
        name="$(basename "$arg")"
        px sh -c "cat > $work/$name" <"$arg"
        uploaded+=("$name")
        args+=("$name")
        continue
    fi
    args+=("$arg")
done

tty=()
[ -t 0 ] && [ -t 1 ] && tty=(-t)
status=0
k exec -i "${tty[@]}" "$pod" -c "$container" -- sh -c 'cd "$1" && shift && exec /opt/netbox/venv/bin/python cfg2nb.pyz "$@"' \
    sh "$work" "${args[@]}" || status=$?

index=0
for name in "${outputs_remote[@]:-}"; do
    [ -n "$name" ] || continue
    if px test -f "$work/$name"; then
        px cat "$work/$name" >"${outputs_local[$index]}"
        echo "copied back: ${outputs_local[$index]}"
    fi
    index=$((index + 1))
done
exit "$status"
