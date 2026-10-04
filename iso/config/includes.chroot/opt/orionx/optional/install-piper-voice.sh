#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE12-046
# @title Piper post-boot installer — the natural voice for R.A.I.N. speech
# @status accepted
# @rationale R.A.I.N. speaks (DEC-PHASE12-046): Nebula writes one sentence, a
#   TTS engine says it. Two engines can do the saying, and the choice was made
#   on measured bytes, not taste:
#
#     espeak-ng            already in iso/config/package-lists/orionx.list.chroot
#                          -> 0 additional ISO bytes. Robotic, fully intelligible.
#     piper + lessac-med   en_US-lessac-medium.onnx is 63,201,294 bytes raw and
#                          58,054,832 bytes under `xz -9` — ONNX fp32 weights
#                          compress by only 8.1%, so the squashfs will not save
#                          you. Add onnxruntime and numpy and the real cost of
#                          a nicer voice is comfortably over 150 MB installed.
#
#   So the image ships espeak-ng and this script is the opt-in upgrade path,
#   exactly like install-zeek.sh (DEC-PHASE12-028). rain_speech.tts_backend()
#   DISCOVERS piper at runtime — install it today or in six months, nothing
#   needs rebuilding and no config changes. If you never run this, R.A.I.N.
#   still speaks; it just sounds like 1998.
#
#   The model is pinned by SHA-256, not by "latest". A voice model is executed
#   by onnxruntime on a deck used for incident response; running whatever the
#   CDN hands back is not acceptable there. A digest mismatch leaves nothing
#   installed and the deck keeps using espeak-ng.
#
#   Rule 3 of docs/RESILIENCE.md: exit 0 from pip and curl is not proof. This
#   installer finishes by SYNTHESISING REAL AUDIO from the installed voice and
#   checking that the result is a RIFF WAV of plausible length. If that fails,
#   the install is declared failed even though every command "succeeded".
#
# Usage:
#   sudo /opt/orionx/optional/install-piper-voice.sh
#   sudo /opt/orionx/optional/install-piper-voice.sh --check   # report only
#   sudo /opt/orionx/optional/install-piper-voice.sh --force   # reinstall
#   /opt/orionx/optional/install-piper-voice.sh --verify-only  # re-run the CHECK

set -uo pipefail

# shellcheck disable=SC1090,SC1091
source "${ORIONX_INSTALLER_LIB:-/opt/orionx/optional/lib/orionx-installer-common.sh}"

# Overridable so the install can live on a persistence volume, and so the
# --verify-only CHECK is runnable without root (RESILIENCE rule 1: a
# verification nobody can run is not a verification).
VOICE_DIR="${ORIONX_VOICE_DIR:-/usr/share/orionx/voices}"
VOICE="$VOICE_DIR/en_US-lessac-medium.onnx"
VOICE_CFG="$VOICE.json"
BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium"
VOICE_SHA256="5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f"
CFG_SHA256="efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0"
VOICE_BYTES=63201294

MODE="install"
for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --force) MODE="force" ;;
        --verify-only) MODE="verify" ;;
        -h|--help)
            sed -n '35,39p' "$0"
            exit 0 ;;
        *)
            orionx_log_error "unknown argument: $arg (see --help)"
            exit 2 ;;
    esac
done

have_piper() { command -v piper >/dev/null 2>&1; }
have_voice() { [[ -f "$VOICE" && -f "$VOICE_CFG" ]]; }

report() {
    if have_piper; then
        orionx_log_info "piper binary : $(command -v piper)"
    else
        orionx_log_info "piper binary : ABSENT"
    fi
    if have_voice; then
        orionx_log_info "voice model  : $VOICE ($(stat -c%s "$VOICE" 2>/dev/null || echo '?') bytes)"
    else
        orionx_log_info "voice model  : ABSENT"
    fi
    if have_piper && have_voice; then
        orionx_log_info "R.A.I.N. speech will use piper."
        orionx_log_info "  Verify with: orionx-rain --speech-status"
    else
        orionx_log_info "R.A.I.N. speech will use espeak-ng (shipped). Nothing is broken."
        orionx_log_info "  Natural voice: sudo $0"
    fi
}

# RESILIENCE rule 3: pip exiting 0 and curl exiting 0 prove that pip and curl
# ran. They do not prove this deck can speak. The only evidence that counts is
# a WAV file with audio in it, produced by the voice that was just installed.
# The install path and --verify-only call this same function.
verify_synthesis() {
    if ! have_piper; then
        orionx_log_error "no piper on PATH — nothing to verify"
        return 1
    fi
    if [[ ! -f "$VOICE" ]]; then
        orionx_log_error "no voice model at $VOICE — nothing to verify"
        return 1
    fi
    orionx_log_info "verifying by synthesising actual audio"
    PROBE="$(mktemp -t piper-probe.XXXXXX)" || return 1
    if ! printf 'Port scan from 192 dot 168 dot 4 dot 77.' \
            | piper -m "$VOICE" -f "$PROBE" >/dev/null 2>&1; then
        orionx_log_error "piper ran but failed to synthesise."
        orionx_log_error "  R.A.I.N. keeps using espeak-ng. Diagnose with:"
        orionx_log_error "  echo hello | piper -m $VOICE -f ./t.wav"
        return 1
    fi
    local probe_bytes
    probe_bytes="$(stat -c%s "$PROBE" 2>/dev/null || stat -f%z "$PROBE" 2>/dev/null || echo 0)"
    # A RIFF header alone is 44 bytes; one second of 22.05 kHz mono s16 is ~44 kB.
    if [[ "$probe_bytes" -le 8000 ]]; then
        orionx_log_error "piper produced only ${probe_bytes} bytes — not real speech"
        return 1
    fi
    if ! head -c 4 "$PROBE" | grep -q RIFF; then
        orionx_log_error "piper output is not a RIFF WAV — refusing to call this working"
        return 1
    fi
    orionx_log_info "verified: ${probe_bytes} bytes of RIFF WAV from the installed voice"
    return 0
}

if [[ "$MODE" == "check" ]]; then
    report
    exit 0
fi

if [[ "$MODE" == "verify" ]]; then
    PROBE=""
    trap 'rm -f "$PROBE"' EXIT
    verify_synthesis || exit 1
    report
    exit 0
fi

if [[ "$MODE" != "force" ]] && have_piper && have_voice; then
    orionx_log_info "already installed — nothing to do (--force to reinstall)"
    report
    exit 0
fi

orionx_log_info "=== Orion-X optional installer: piper voice for R.A.I.N. ==="
orionx_log_info "  Size:    ${VOICE_BYTES} bytes voice model + onnxruntime/numpy"
orionx_log_info "  License: MIT (piper) / CC-BY-4.0 (lessac voice, Blizzard 2013)"
orionx_log_info "  Without it: R.A.I.N. speaks via espeak-ng. Nothing is lost but timbre."

orionx_require_root
orionx_require_network huggingface.co

TMP_ONNX=""
TMP_CFG=""
PROBE=""
cleanup() { rm -f "$TMP_ONNX" "$TMP_CFG" "$PROBE"; }
trap cleanup EXIT

# --- the engine ------------------------------------------------------------
if ! have_piper || [[ "$MODE" == "force" ]]; then
    orionx_log_info "installing piper-tts (pulls onnxruntime + numpy)"
    if ! pip3 install --break-system-packages -q piper-tts; then
        orionx_log_error "pip3 install piper-tts failed."
        orionx_log_error "  Nothing was changed; espeak-ng still speaks for R.A.I.N."
        exit 1
    fi
    if ! have_piper; then
        orionx_log_error "piper-tts installed but no 'piper' on PATH."
        orionx_log_error "  Check: pip3 show piper-tts; ls /usr/local/bin/piper"
        exit 1
    fi
fi

# --- the voice, pinned, staged, then moved into place ----------------------
if ! mkdir -p "$VOICE_DIR"; then
    orionx_log_error "cannot create $VOICE_DIR"
    exit 1
fi

if ! have_voice || [[ "$MODE" == "force" ]]; then
    orionx_log_info "fetching the voice model (${VOICE_BYTES} bytes, SHA-256 pinned)"
    TMP_ONNX="$(mktemp "${VOICE}.XXXXXX")" || exit 1
    TMP_CFG="$(mktemp "${VOICE_CFG}.XXXXXX")" || exit 1
    if ! curl -fsSL --retry 2 -o "$TMP_ONNX" "$BASE/en_US-lessac-medium.onnx"; then
        orionx_log_error "download failed; nothing installed, espeak-ng remains in use"
        exit 1
    fi
    if ! curl -fsSL --retry 2 -o "$TMP_CFG" "$BASE/en_US-lessac-medium.onnx.json"; then
        orionx_log_error "config download failed; nothing installed"
        exit 1
    fi
    # Verified BEFORE anything lands in $VOICE_DIR, so a tampered or truncated
    # model is never visible to rain_speech.piper_voice() even for an instant.
    orionx_verify_sha256 "$TMP_ONNX" "$VOICE_SHA256"
    orionx_verify_sha256 "$TMP_CFG" "$CFG_SHA256"
    chmod 0644 "$TMP_ONNX" "$TMP_CFG"
    mv -f "$TMP_ONNX" "$VOICE" && TMP_ONNX=""
    mv -f "$TMP_CFG" "$VOICE_CFG" && TMP_CFG=""
fi

# --- CHECK: synthesise real audio; do not trust exit codes -----------------
verify_synthesis || exit 1

report
orionx_log_info "done. R.A.I.N. picks piper up on its next narration; no restart needed."
exit 0
