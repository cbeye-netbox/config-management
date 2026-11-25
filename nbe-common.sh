# Shared by the scripts of this kit: find kubectl and the NetBox pods of NetBox Enterprise.
# Sourced, not run.
#
# Environment:
#   KUBECTL        kubectl command (default: the one of the embedded cluster, with sudo
#                  when not root; else kubectl from PATH)
#   NBE_NAMESPACE  namespace of NetBox Enterprise (default kotsadm)

namespace="${NBE_NAMESPACE:-kotsadm}"
embedded=/var/lib/embedded-cluster/bin/kubectl
admin_conf=/var/lib/embedded-cluster/k0s/pki/admin.conf
if [ -n "${KUBECTL:-}" ]; then
    read -r -a kubectl <<<"$KUBECTL"
elif [ -x "$embedded" ]; then
    kubectl=(env "KUBECONFIG=$admin_conf" "$embedded")
    [ "$(id -u)" = 0 ] || kubectl=(sudo "${kubectl[@]}")
elif command -v kubectl >/dev/null 2>&1; then
    kubectl=(kubectl)
else
    echo "No kubectl found. Run this on the NetBox Enterprise host, or set KUBECTL." >&2
    exit 2
fi
k() { "${kubectl[@]}" -n "$namespace" "$@"; }

# First running pod with a label, or nothing.
pod_with() {
    k get pods -l "$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
web_pod() { pod_with netboxlabs.com/custom-plugins-upload=true; }
worker_pod() { pod_with netboxlabs.com/component=netbox-worker; }
