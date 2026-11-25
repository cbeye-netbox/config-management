#!/usr/bin/env bash
# Copy wheelhouse.tar.gz into the media volume of NetBox Enterprise and check it there.
#
#   ./plugin-upload.sh
#
# NetBox Enterprise installs the archive from /opt/netbox/netbox/media/wheelhouse.tar.gz
# each time a NetBox pod starts. The copy itself restarts nothing.
#
# The archive goes straight into the media volume, which is on disk. Never put it into
# a pod's /tmp: that directory is memory-backed and counts against the memory limit of
# the container.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/nbe-common.sh"

file="$here/wheelhouse.tar.gz"
target=/opt/netbox/netbox/media/wheelhouse.tar.gz
[ -f "$file" ] || { echo "wheelhouse.tar.gz not found next to this script" >&2; exit 2; }
pod="$(web_pod)"
[ -n "$pod" ] || { echo "no running NetBox pod found in namespace $namespace" >&2; exit 2; }

local_sum="$(sha256sum "$file" | cut -d' ' -f1)"
remote_sum="$(k exec "$pod" -c netbox -- sh -c "[ -e $target ] && sha256sum $target | cut -d' ' -f1 || true")"
if [ "$local_sum" = "$remote_sum" ]; then
    echo "The media volume already holds this wheelhouse (sha256 $local_sum). Nothing copied."
    exit 0
fi
if [ -n "$remote_sum" ] && [ "${1:-}" != "--replace" ]; then
    echo "The media volume holds ANOTHER wheelhouse.tar.gz (sha256 $remote_sum)." >&2
    echo "Replacing it removes the plugins it carries. To replace it anyway: $0 --replace" >&2
    exit 1
fi

echo "copying $(du -h "$file" | cut -f1) to $pod:$target ..."
k cp "$file" "$namespace/$pod:$target" -c netbox
remote_sum="$(k exec "$pod" -c netbox -- sh -c "sha256sum $target | cut -d' ' -f1")"
if [ "$local_sum" != "$remote_sum" ]; then
    echo "The copy differs from the file (sha256 $remote_sum, expected $local_sum). Copy it again." >&2
    exit 1
fi
k exec "$pod" -c netbox -- sh -c "gzip -t $target && tar -tzf $target | grep -c '\.whl$'" |
    sed 's/$/ wheels in the archive, readable/'
echo "sha256 $remote_sum: the copy is identical."
echo "Next: add the plugin in the admin console (1-INSTALL-PLUGIN.md, step 4)."
