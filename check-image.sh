#!/usr/bin/env bash
# Check that this NetBox Enterprise runs the image the wheelhouse was built for,
# and show the memory limit of the NetBox pods. Changes nothing.
#
#   ./check-image.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/nbe-common.sh"

expected="nbe-core:4.7.3_2.5.0-10212.g4f1cf7560"
pod="$(web_pod)"
[ -n "$pod" ] || { echo "no running NetBox pod found in namespace $namespace" >&2; exit 2; }
image="$(k get pod "$pod" -o jsonpath='{.spec.containers[?(@.name=="netbox")].image}')"
echo "NetBox pod:   $pod"
echo "image:        $image"
status=0
case "$image" in
    *"$expected") echo "result:       same image as the one the wheelhouse was built and tested for" ;;
    *)
        echo "result:       ANOTHER image than the one the wheelhouse was built for ($expected)"
        echo "              Do not install this wheelhouse. Build a new one against this image:"
        echo "              image-packages.txt in this kit lists the versions it was built against."
        status=1
        ;;
esac

echo
echo "NetBox pods and their memory limit (the plugin needs the Large preset, 3000Mi):"
k get pods -l netboxlabs.com/custom-plugins-upload=true \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[?(@.name=="netbox")].ready,MEMORY-LIMIT:.spec.containers[?(@.name=="netbox")].resources.limits.memory'
k get pods -l netboxlabs.com/component=netbox-worker \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,MEMORY-LIMIT:.spec.containers[0].resources.limits.memory'

echo
if k exec "$pod" -c netbox -- test -e /opt/netbox/netbox/media/wheelhouse.tar.gz 2>/dev/null; then
    echo "media volume: a wheelhouse.tar.gz is ALREADY there. plugin-upload.sh would replace it."
    echo "              If it holds other plugins, they must be built into one common wheelhouse."
else
    echo "media volume: no wheelhouse.tar.gz yet"
fi
exit "$status"
