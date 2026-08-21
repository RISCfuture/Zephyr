#!/bin/bash
#
# Turns the screenshot suite's result bundle into the three image sets Zephyr publishes.
#
#   Scripts/export-screenshots.sh <result-bundle.xcresult> <site-images-dir> <app-store-dir> \
#                                 <help-images-dir> <slug>…
#
# XCUITest cannot hand a file back to its caller: xcodebuild forwards no shell environment into the
# runner process, so the tests cannot be told where to write and instead attach every capture to the
# result bundle. This unpacks that bundle, recovers each attachment's name, converts the capture out
# of the capturing display's colour space, and then writes:
#
#   * <site-images-dir>/<slug>.webp — every still capture, light and dark, for the marketing site.
#   * <site-images-dir>/<slug>.png — an APNG, for a capture the suite took as a numbered sequence,
#     alongside a <slug>.webp of its first page for readers who have asked for reduced motion.
#     A slug ending in "-<n>" is frame n of an animation named by the rest of it, so `setup-1`,
#     `setup-2`, … become `setup.png`, and `setup-dark-1`, … become `setup-dark.png`. APNG rather
#     than GIF because these are screenshots: 256 colours band the icon's gradient and dither the
#     window's material, and an APNG of flat UI is barely larger than the frames it holds.
#   * <help-images-dir>/<slug>.webp — the same stills again, for the Apple Help book. One capture
#     run feeds the site, the store, and the book, so a page in the book can never illustrate an
#     older build than the site does. The APNG is deliberately not copied: a looping animation is
#     the one thing a help page must not carry, so the book embeds the first-page still instead.
#
#   * <app-store-dir>/NN-<slug>.png — the trailing <slug> arguments, in the order given, each
#     centred on a canvas of an App Store screenshot size. Only light captures are framed; the
#     listing shows one appearance, and it is the one the store's own chrome is drawn in. A slug
#     naming an animation is framed from its first page, since a listing takes stills.
#
# xcresulttool names exported files by UUID and records the name the test asked for only in
# manifest.json, mangled to "<slug>_<index>_<UUID>.png". The slug is recovered from that suffix,
# which is why the tests are required to name attachments as bare [a-z0-9-]+ slugs: a dot in the
# name is re-read as an extension and the recovery would silently mis-file the image.
#
# Owns all three output directories outright — each is emptied first, so a screenshot dropped from
# the manifest leaves no stale file behind. That ownership is why a bundle carrying no named
# attachments is a hard error rather than a no-op: an empty export means the suite was skipped or its
# attachments were not kept, and quietly emptying the published images over that would be a worse
# outcome than stopping. Which slugs must be present is the caller's business; this maps whatever it
# finds and prints each file it writes.

set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "usage: $(basename "$0") <result-bundle> <site-images-dir> <app-store-dir>" \
       "<help-images-dir> <slug>..." >&2
  exit 2
fi

BUNDLE="$1"
IMAGES="$2"
STORE="$3"
HELP_IMAGES="$4"
shift 4
STORE_SLUGS=("$@")

SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

# An App Store screenshot for macOS has to be exactly one of four sizes, and this is the largest —
# the only one a 2× capture of a window this size lands inside without being scaled down.
readonly CANVAS_WIDTH=2560
readonly CANVAS_HEIGHT=1600

# The fill the windows are staged and framed on: the marketing site's tinted band, which is also
# what ScreenshotStaging draws behind the app, so a capture's rounded corners meet the canvas
# without a seam.
readonly CANVAS_COLOR='#edf2fa'

# How much of the canvas a framed window should span, and how far it may be scaled to get there.
# Zephyr's windows are small — the menu-bar panel is 320 points wide — so at native size they read
# as lost on a 2560-pixel canvas. The ceiling is what keeps the enlargement short of the point where
# a 2× capture starts to look like a 1× one.
readonly TARGET_WIDTH_FRACTION=0.55
readonly MAX_HEIGHT_FRACTION=0.80
readonly MAX_SCALE=1.6

# How long each page of an animation holds, in hundredths of a second. Long enough to read a page of
# setup without the loop turning into a slideshow nobody waits out.
readonly FRAME_DELAY=200

[ -d "${BUNDLE}" ] || { echo "error: no result bundle at ${BUNDLE}" >&2; exit 1; }
[ -f "${SRGB_PROFILE}" ] || { echo "error: no sRGB profile at ${SRGB_PROFILE}" >&2; exit 1; }

for TOOL in magick cwebp ffmpeg; do
  command -v "${TOOL}" >/dev/null ||
    { echo "error: ${TOOL} is not installed (brew install ${TOOL})" >&2; exit 1; }
done

# xcresulttool refuses to overwrite: exporting into a populated directory writes "UUID (1).png"
# siblings rather than replacing anything, so the export target has to be freshly made.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ATTACHMENTS="${WORK}/attachments"
INDEX="${WORK}/index.tsv"

# The per-test "no matching attachments" chatter is stdout noise; a real failure still reaches
# stderr and still trips the exit-on-error.
xcrun xcresulttool export attachments \
  --path "${BUNDLE}" \
  --output-path "${ATTACHMENTS}" >/dev/null

# Python rather than a text filter: the manifest is JSON, and the field order it happens to print in
# is not part of any contract. Anything whose name does not match the slug grammar is another test's
# attachment and is left alone.
/usr/bin/python3 - "${ATTACHMENTS}/manifest.json" >"${INDEX}" <<'PYTHON'
import json, re, sys

MANGLED = re.compile(
    r"^(?P<slug>[a-z0-9-]+)_\d+_"
    r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.png$"
)

with open(sys.argv[1]) as manifest:
    for test in json.load(manifest):
        for attachment in test.get("attachments", []):
            match = MANGLED.match(attachment.get("suggestedHumanReadableName", ""))
            if match:
                print(f"{attachment['exportedFileName']}\t{match['slug']}")
PYTHON

if [ ! -s "${INDEX}" ]; then
  echo "error: no named screenshot attachments in ${BUNDLE}" >&2
  echo "       the capture suite was skipped, or its attachments were not kept" >&2
  exit 1
fi

rm -rf "${IMAGES}" "${STORE}" "${HELP_IMAGES}"
mkdir -p "${IMAGES}" "${STORE}" "${HELP_IMAGES}"

# sips converts the pixels out of the capturing display's profile but leaves the input's stale XMP
# in place; ImageMagick then strips the metadata, which is the only part of its output that is not a
# function of the pixels — it stamps a tIME chunk and three date: text chunks that would otherwise
# make every regeneration a diff.
flatten_capture() {
  local exported="$1" flat="$2"
  sips --matchTo "${SRGB_PROFILE}" "${ATTACHMENTS}/${exported}" --out "${WORK}/srgb.png" >/dev/null
  magick "${WORK}/srgb.png" -strip "${flat}"
}

# cwebp embeds neither a timestamp nor a version string, so the encode is byte-identical run to run:
# -exact preserves the RGB under the transparent pixels a window capture's rounded corners carry,
# and -sharp_yuv earns its cost on UI text.
write_site_image() {
  local flat="$1" slug="$2"
  cwebp -quiet -q 90 -m 6 -sharp_yuv -exact "${flat}" -o "${IMAGES}/${slug}.webp"
  echo "${IMAGES}/${slug}.webp"
  # Copied rather than re-encoded: cwebp is deterministic, so a second encode would produce the
  # same bytes at the cost of running it twice.
  cp "${IMAGES}/${slug}.webp" "${HELP_IMAGES}/${slug}.webp"
  echo "${HELP_IMAGES}/${slug}.webp"
}

# How far to scale `flat`, as the percentage `magick -resize` wants: enough to put it at
# TARGET_WIDTH_FRACTION of the canvas, held under MAX_SCALE and under the height the canvas has room
# for. The height rule is what decides for a tall window — Settings runs to well over a thousand
# points — and it shrinks, because a capture the canvas cannot hold has to be made to fit rather
# than composited at native size and cropped.
frame_scale_percent() {
  local flat="$1"
  magick identify -format "%w %h" "${flat}" | awk \
    -v cw="${CANVAS_WIDTH}" -v ch="${CANVAS_HEIGHT}" -v target="${TARGET_WIDTH_FRACTION}" \
    -v maxheight="${MAX_HEIGHT_FRACTION}" -v ceiling="${MAX_SCALE}" '{
      scale = cw * target / $1
      if (scale > ceiling) scale = ceiling
      if (scale > ch * maxheight / $2) scale = ch * maxheight / $2
      printf "%.2f", scale * 100
    }'
}

# Flattened onto an opaque canvas: App Store Connect rejects a screenshot carrying an alpha channel,
# and a window capture has one wherever its corners are rounded.
write_app_store_image() {
  local flat="$1" name="$2"
  magick -size "${CANVAS_WIDTH}x${CANVAS_HEIGHT}" "xc:${CANVAS_COLOR}" \
    \( "${flat}" -filter Lanczos -resize "$(frame_scale_percent "${flat}")%" \) \
    -gravity center -composite \
    -alpha remove -alpha off -strip "${STORE}/${name}.png"
  echo "${STORE}/${name}.png"
}

# The frames of one animation, in page order, as an APNG.
#
# ffmpeg rather than ImageMagick, whose APNG coder does not round-trip a colour: it writes
# rgb(247,246,243) back as rgb(245,244,238), and no combination of -colorspace, -set gamma, or
# excluded chunks stops it. Two or three levels is nothing on a photograph and everything here — the
# margin around each capture is a flat fill chosen to match the page, and a flat fill that misses
# by three levels is a visible rectangle.
#
# The extension is .png, not .apng: the file has to be served as image/png for a browser to play it,
# and a static host decides that from the name.
write_animation() {
  local frames="$1" family="$2"
  ffmpeg -y -loglevel error \
    -framerate "100/${FRAME_DELAY}" -i "${frames}/%03d.png" \
    -plays 0 -pix_fmt rgb24 -f apng "${IMAGES}/${family}.png"
  echo "${IMAGES}/${family}.png"
  # The first page as a still as well. A looping animation is the one thing a reader who has asked
  # for reduced motion must not be given, and there is no pausing an APNG — so the page offers this
  # instead.
  write_site_image "$(first_frame "${frames}")" "${family}"
}

# An animation's first page, for the still the App Store takes.
first_frame() {
  local frames="$1"
  find "${frames}" -name '*.png' | sort | head -1
}

# Every capture reaches the site; only the slugs the caller named reach the store, numbered in the
# order they were named because App Store Connect orders a screenshot set by file name.
declare -a STORE_POSITION
position=1
for slug in "${STORE_SLUGS[@]}"; do
  STORE_POSITION+=("${slug}=$(printf '%02d' "${position}")")
  position=$((position + 1))
done

app_store_name() {
  local slug="$1" entry
  for entry in "${STORE_POSITION[@]}"; do
    if [ "${entry%%=*}" = "${slug}" ]; then
      echo "${entry##*=}-${slug}"
      return 0
    fi
  done
  return 1
}

# Frames are collected under their animation's name and assembled once the whole manifest has been
# read, because the manifest lists attachments in whatever order the run produced them and an
# animation has to be built in page order.
FRAMES="${WORK}/frames"

while IFS=$'\t' read -r EXPORTED SLUG; do
  # The family has to end in a non-digit, or a greedy match splits frame 12 of "setup" into frame 2
  # of "setup-1" and the tenth page onwards lands in an animation of its own.
  if [[ "${SLUG}" =~ ^(.*[^0-9])-([0-9]+)$ ]]; then
    FAMILY="${BASH_REMATCH[1]}"
    mkdir -p "${FRAMES}/${FAMILY}"
    flatten_capture "${EXPORTED}" \
      "$(printf '%s/%s/%03d.png' "${FRAMES}" "${FAMILY}" "${BASH_REMATCH[2]}")"
    continue
  fi
  FLAT="${WORK}/${SLUG}.png"
  flatten_capture "${EXPORTED}" "${FLAT}"
  write_site_image "${FLAT}" "${SLUG}"
  if NAME="$(app_store_name "${SLUG}")"; then
    write_app_store_image "${FLAT}" "${NAME}"
  fi
done <"${INDEX}"

for FAMILY_PATH in "${FRAMES}"/*/; do
  [ -d "${FAMILY_PATH}" ] || continue
  FAMILY="$(basename "${FAMILY_PATH}")"
  write_animation "${FAMILY_PATH}" "${FAMILY}"
  if NAME="$(app_store_name "${FAMILY}")"; then
    write_app_store_image "$(first_frame "${FAMILY_PATH}")" "${NAME}"
  fi
done
