#!/bin/bash
#
# Run inside the screenshot VM. Writes the demo account's fictional files into its Zephyr domain,
# then evicts some of them, so Finder shows downloaded and cloud-only items side by side.
#
#   populate-demo-account.sh <content-dir>
#
# <content-dir> is what generate-demo-content.swift writes, run on the host into the `out` share.
# Writing through the domain is what puts the files on Dropbox: Zephyr uploads them as they land.
# The App Review notes name Documents, Photos, Projects, and the three-revision Welcome file, so
# this only ever adds to the tree.

set -euo pipefail

content="$1"
domain="$(ls -d "${HOME}"/Library/CloudStorage/Zephyr-*)"

# Downloaded items are the ones the window shows as plain; these are left in the cloud.
readonly CLOUD_ONLY=(
  "Photos/Coastline.jpg" "Photos/Desert Road.jpg" "Photos/Glacier Valley.jpg"
  "Photos/Harbor Sunset.jpg" "Photos/Night Sky over Camp.jpg" "Photos/Pine Forest Trail.jpg"
  "Documents/Lease Renewal.pdf" "Projects/Garden/Planting Plan.pdf"
  "Projects/Cabin Renovation/Contractor Estimate.pdf"
)

# Evicts one item, failing until it has finished uploading. `fileproviderctl` on macOS 27 has no
# evict verb; Foundation's evictUbiquitousItem works on any File Provider item, and JXA reaches it
# without a compiler, which the guest does not have.
evict() {
  osascript -l JavaScript - "$1" <<'JS' >/dev/null
ObjC.import("Foundation");
function run(argv) {
  const url = $.NSURL.fileURLWithPath(argv[0]);
  if (!$.NSFileManager.defaultManager.evictUbiquitousItemAtURLError(url, null)) throw new Error("not evictable");
}
JS
}

ditto "${content}" "${domain}"
echo "copied into ${domain}; evicting once uploaded"

for attempt in $(seq 1 30); do
  pending=()
  for item in "${CLOUD_ONLY[@]}"; do
    # shellcheck disable=SC2310 # a failed eviction is an item still uploading, not an error
    evict "${domain}/${item}" 2>/dev/null || pending+=("${item}")
  done
  [ "${#pending[@]}" -eq 0 ] && { echo "done"; exit 0; }
  echo "attempt ${attempt}: ${#pending[@]} still uploading"
  sleep 10
done
echo "error: never evictable: ${pending[*]}" >&2
exit 1
