#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_LAYOUT_URL="https://configure.zsa.io/voyager/layouts/JRDrZ/latest/0"
readonly GRAPHQL_URL="https://oryx.zsa.io/graphql"
readonly SOURCE_BASE_URL="https://oryx.zsa.io/source"
readonly REQUIRED_FILES=(config.h i18n.h keymap.c keymap.json rules.mk)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

LAYOUT_URL="${1:-$DEFAULT_LAYOUT_URL}"
DEST_DIR="${2:-keyboards/zsa/voyager/keymaps/kikos}"
PATCH_FILE="${3:-layer-switch-winspace.patch}"
MAKE_TARGET="${MAKE_TARGET:-voyager:kikos:flash}"

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$path"
  fi
}

need_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

for tool in curl jq unzip patch make; do
  need_tool "$tool"
done

DEST_DIR="$(resolve_path "$DEST_DIR")"
PATCH_FILE="$(resolve_path "$PATCH_FILE")"
PATCH_TARGET_FILE="${PATCH_TARGET_FILE:-$DEST_DIR/keymap.c}"
PATCH_TARGET_FILE="$(resolve_path "$PATCH_TARGET_FILE")"

if [[ ! -d "$DEST_DIR" ]]; then
  echo "Destination directory does not exist: $DEST_DIR" >&2
  exit 1
fi

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "Patch file does not exist: $PATCH_FILE" >&2
  exit 1
fi

if [[ "$LAYOUT_URL" =~ ^https://configure\.zsa\.io/([^/]+)/layouts/([^/]+)/([^/]+)/[0-9]+/?$ ]]; then
  GEOMETRY="${BASH_REMATCH[1]}"
  LAYOUT_ID="${BASH_REMATCH[2]}"
  REVISION_ID="${BASH_REMATCH[3]}"
else
  echo "Unexpected layout URL format: $LAYOUT_URL" >&2
  echo "Expected: https://configure.zsa.io/<geometry>/layouts/<layout-id>/<revision-id>/<layer>" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Resolving revision hash from $LAYOUT_URL ..."
GRAPHQL_PAYLOAD="$(jq -cn \
  --arg hashId "$LAYOUT_ID" \
  --arg revisionId "$REVISION_ID" \
  --arg geometry "$GEOMETRY" \
  '{
    query: "query getLayout($hashId:String!, $revisionId:String!, $geometry:String){layout(hashId:$hashId, geometry:$geometry, revisionId:$revisionId){revision{hashId}}}",
    variables: {
      hashId: $hashId,
      revisionId: $revisionId,
      geometry: $geometry
    }
  }')"

GRAPHQL_RESPONSE="$(curl -fsSL \
  -X POST "$GRAPHQL_URL" \
  -H 'content-type: application/json' \
  --data "$GRAPHQL_PAYLOAD")"

if [[ "$(echo "$GRAPHQL_RESPONSE" | jq '.errors != null')" == "true" ]]; then
  echo "GraphQL request failed:" >&2
  echo "$GRAPHQL_RESPONSE" | jq -r '.errors[]?.message' >&2
  exit 1
fi

REVISION_HASH="$(echo "$GRAPHQL_RESPONSE" | jq -r '.data.layout.revision.hashId // empty')"
if [[ -z "$REVISION_HASH" ]]; then
  echo "Could not resolve revision hash from Oryx response." >&2
  exit 1
fi

ZIP_URL="${SOURCE_BASE_URL}/${REVISION_HASH}"
ZIP_PATH="${TMP_DIR}/source.zip"
UNPACK_DIR="${TMP_DIR}/unzipped"

echo "Downloading source ZIP from ${ZIP_URL} ..."
curl -fL --retry 3 --retry-delay 1 "$ZIP_URL" -o "$ZIP_PATH"

echo "Unzipping archive ..."
mkdir -p "$UNPACK_DIR"
unzip -q "$ZIP_PATH" -d "$UNPACK_DIR"

SOURCE_DIR="$(find "$UNPACK_DIR" -mindepth 1 -maxdepth 2 -type d -name '*_source' | head -n 1 || true)"
if [[ -z "$SOURCE_DIR" ]]; then
  if [[ -f "$UNPACK_DIR/keymap.c" ]]; then
    SOURCE_DIR="$UNPACK_DIR"
  else
    echo "Could not find extracted *_source directory in ZIP." >&2
    exit 1
  fi
fi

echo "Copying generated files into ${DEST_DIR} ..."
for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$SOURCE_DIR/$file" ]]; then
    echo "Missing file in extracted source: $SOURCE_DIR/$file" >&2
    exit 1
  fi
  cp "$SOURCE_DIR/$file" "$DEST_DIR/$file"
done

cd "$REPO_ROOT"
echo "Applying patch ${PATCH_FILE} to ${PATCH_TARGET_FILE} ..."
PATCH_FORWARD_LOG="${TMP_DIR}/patch-forward.log"
PATCH_REVERSE_LOG="${TMP_DIR}/patch-reverse.log"

if patch --dry-run "$PATCH_TARGET_FILE" < "$PATCH_FILE" >"$PATCH_FORWARD_LOG" 2>&1; then
  patch "$PATCH_TARGET_FILE" < "$PATCH_FILE"
elif patch --dry-run -R "$PATCH_TARGET_FILE" < "$PATCH_FILE" >"$PATCH_REVERSE_LOG" 2>&1; then
  echo "Patch appears to be already applied; skipping."
elif [[ -f "$PATCH_TARGET_FILE" ]] \
  && grep -Fq 'static bool layer5_space_shift_from_ctrl_bspc = false;' "$PATCH_TARGET_FILE" \
  && grep -Fq 'if (record->event.pressed && QK_MODS_GET_BASIC_KEYCODE(keycode) == KC_SPACE && (QK_MODS_GET_MODS(keycode) & MOD_MASK_GUI) != 0) {' "$PATCH_TARGET_FILE" \
  && grep -Fq 'case KC_ESCAPE:' "$PATCH_TARGET_FILE" \
  && grep -Fq 'del_oneshot_mods(MOD_MASK_SHIFT);' "$PATCH_TARGET_FILE" \
  && grep -Fq 'case QK_MOD_TAP ... QK_MOD_TAP_MAX: {' "$PATCH_TARGET_FILE" \
  && grep -Fq 'bool is_ctrl_backspace = mt_tap_keycode == KC_BSPC && ((mt_mods & MOD_LCTL) == MOD_LCTL);' "$PATCH_TARGET_FILE" \
  && grep -Fq 'add_oneshot_mods(MOD_BIT_LSHIFT);' "$PATCH_TARGET_FILE" \
  && grep -Fq 'case KC_SPACE:' "$PATCH_TARGET_FILE" \
  && grep -Fq 'bool is_gui_space_combo = (get_mods() & MOD_MASK_GUI) != 0;' "$PATCH_TARGET_FILE" \
  && grep -Fq 'if (layer5_space_shift_from_ctrl_bspc) {' "$PATCH_TARGET_FILE" \
  && grep -Fq 'if (layer_state_is(5) && record->tap.count > 0) {' "$PATCH_TARGET_FILE" \
  && grep -Fq 'layer_move(layer_state_is(1) ? 0 : 1);' "$PATCH_TARGET_FILE"; then
  echo "Patch markers already found in ${PATCH_TARGET_FILE}; skipping."
elif [[ -f "$PATCH_TARGET_FILE" ]] \
  && (grep -Fq 'case QK_TO ... QK_TO_MAX:' "$PATCH_TARGET_FILE" || grep -Fq 'case TO(0):' "$PATCH_TARGET_FILE" || grep -Fq 'case TO(1):' "$PATCH_TARGET_FILE") \
  && grep -Fq 'tap_code16(LGUI(KC_SPACE));' "$PATCH_TARGET_FILE"; then
  echo "Found an older TO-handler patch in ${PATCH_TARGET_FILE}; please refresh and reapply ${PATCH_FILE}." >&2
  exit 1
else
  echo "Patch does not apply cleanly: $PATCH_FILE" >&2
  if [[ -s "$PATCH_FORWARD_LOG" ]]; then
    echo "patch --dry-run output:" >&2
    sed 's/^/  /' "$PATCH_FORWARD_LOG" >&2
  fi
  exit 1
fi

echo "Cleaning temporary files ..."
cleanup
trap - EXIT

if [[ "${SKIP_FLASH:-0}" == "1" ]]; then
  echo "Skipping flash build because SKIP_FLASH=1."
else
  echo "Running flash build ..."
  make "$MAKE_TARGET"
fi

echo "Done."
