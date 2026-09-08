#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tests for verify_download.sh — offline, deterministic, no network.
#
# Checksum assets are served from a local directory via --base-url file://...
# (curl reads file:// natively), and `gh` is replaced by a stub on PATH whose
# answers are driven by STUB_ATTESTATION:
#     none  -> upstream publishes no provenance for this digest
#     ok    -> provenance exists and verifies
#     fail  -> provenance exists but does NOT verify
#
# The OpenPGP layer is exercised with throwaway keys generated into a temporary
# GNUPGHOME, signing the local checksum files for real -- no stub, no network.
# Neither seam can make a bad file pass: the real hash is still computed from
# the real bytes and compared against whatever the checksum file says.
#
# Exit 0 = the download is verified (safe to package);
# exit 1 = mismatch, missing checksum, or failed provenance (build blocked).
#
# Run:  ./test_verify_download.sh
# ---------------------------------------------------------------------------
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/verify_download.sh"
[ -f "$SCRIPT" ] || { echo "verify_download.sh not found next to tests"; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rel="$tmp/release"          # pretend release assets live here
mkdir -p "$rel" "$tmp/bin"
pass=0; fail=0

# --- gh stub ---------------------------------------------------------------
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${STUB_ATTESTATION:-none}" in
  none) exit 1 ;;                                  # no provenance for any digest
  ok)   [ "$1" = "api" ] && exit 0; exit 0 ;;      # exists and verifies
  fail) [ "$1" = "api" ] && exit 0
        echo "stub: signature does not verify" >&2; exit 1 ;;
  # Upstream publishes SOME attestation, but not the predicate we ask for --
  # GitHub now auto-generates an in-toto release/v0.2 record for most public
  # releases. An unfiltered probe answers "yes", the verify then finds nothing.
  otherpredicate)
        if [ "$1" = "api" ]; then
          case "$2" in *predicate_type=*) exit 1 ;; *) exit 0 ;; esac
        fi
        echo "Error: no attestations found" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# --- payload used by most cases --------------------------------------------
PAYLOAD="$rel/tool-x86_64-linux.tar.gz"
printf 'pretend tarball contents\n' > "$PAYLOAD"
GOOD_HASH="$(sha256sum "$PAYLOAD" | awk '{print $1}')"
BAD_HASH="$(printf 'something else' | sha256sum | awk '{print $1}')"

# run <name> <expected_exit> [extra args...]
run() {
  local name="$1" expected="$2"; shift 2
  local out ec
  out="$(bash "$SCRIPT" --repo acme/tool --base-url "file://$rel" "$@" 2>&1)"; ec=$?
  if [ "$ec" = "$expected" ]; then
    printf 'ok   - %s\n' "$name"; pass=$((pass+1))
  else
    printf 'FAIL - %s (expected exit %s, got %s)\n' "$name" "$expected" "$ec"
    printf '%s\n' "$out" | sed 's/^/         /'; fail=$((fail+1))
  fi
}

reset_sums() { rm -f "$rel"/*.sha256 "$rel"/*.sha256sum "$rel"/sha256.sum \
                     "$rel"/SHA256SUMS "$rel"/checksums.txt "$rel"/sha256sums.txt \
                     "$rel"/*.asc; }

echo "== checksum file formats (expect exit 0) =="

reset_sums
printf '%s  tool-x86_64-linux.tar.gz\n' "$GOOD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"
run "per-asset .sha256, two-space form" 0 "$PAYLOAD"

reset_sums
printf '%s *tool-x86_64-linux.tar.gz\n' "$GOOD_HASH" > "$rel/sha256.sum"
run "aggregate sha256.sum, binary '*' form" 0 "$PAYLOAD"

reset_sums
{ printf '%s  other-arch.tar.gz\n' "$BAD_HASH"
  printf '%s  tool-x86_64-linux.tar.gz\n' "$GOOD_HASH"; } > "$rel/SHA256SUMS"
run "SHA256SUMS, correct line picked from many" 0 "$PAYLOAD"

reset_sums
printf '%s  ./tool-x86_64-linux.tar.gz\n' "$GOOD_HASH" > "$rel/checksums.txt"
run "leading ./ on the filename" 0 "$PAYLOAD"

reset_sums
printf '%s  tool-x86_64-linux.tar.gz\r\n' "$GOOD_HASH" > "$rel/checksums.txt"
run "CRLF line endings" 0 "$PAYLOAD"

reset_sums
printf '%s  tool-x86_64-linux.tar.gz\n' "$(printf '%s' "$GOOD_HASH" | tr 'a-f' 'A-F')" \
  > "$rel/tool-x86_64-linux.tar.gz.sha256"
run "uppercase hash" 0 "$PAYLOAD"

reset_sums
printf '%s\n' "$GOOD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"
run "bare hash, no filename column" 0 "$PAYLOAD"

# BSD tag format, as emitted by `sha256sum --tag` and BSD shasum. Upstreams
# using it (yq) list several algorithms for the same file, so the SHA256 line
# must be picked exactly -- matching SHA1 or MD5 would compare the wrong digest.
reset_sums
{ printf 'CRC32 (tool-x86_64-linux.tar.gz) = ae7fa9ce\n'
  printf 'MD5   (tool-x86_64-linux.tar.gz) = 932c2b7be27984ce4747434da0841d62\n'
  printf 'SHA1  (tool-x86_64-linux.tar.gz) = 8edd1ca6cfae231a70cfec19943fad85f224e060\n'
  printf 'SHA256 (tool-x86_64-linux.tar.gz) = %s\n' "$GOOD_HASH"
  printf 'SHA512 (tool-x86_64-linux.tar.gz) = %s%s\n' "$BAD_HASH" "$BAD_HASH"; } \
  > "$rel/checksums-bsd"
run "BSD tag format among many algorithms" 0 "$PAYLOAD"

reset_sums
{ printf 'SHA1  (tool-x86_64-linux.tar.gz) = 8edd1ca6cfae231a70cfec19943fad85f224e060\n'
  printf 'MD5   (tool-x86_64-linux.tar.gz) = 932c2b7be27984ce4747434da0841d62\n'; } \
  > "$rel/checksums-bsd"
run "BSD file with no SHA256 line is not accepted" 1 "$PAYLOAD"

reset_sums
printf 'SHA256 (other-file.tar.gz) = %s\n' "$GOOD_HASH" > "$rel/checksums-bsd"
run "BSD line for a different file is not matched" 1 "$PAYLOAD"

echo
echo "== renamed local file (Debian orig tarball) =="

reset_sums
printf '%s  source.tar.gz\n' "$GOOD_HASH" > "$rel/source.tar.gz.sha256"
cp "$PAYLOAD" "$tmp/tool_1.2.3.orig.tar.gz"
run "--asset-name maps orig tarball to upstream name" 0 \
    --asset-name source.tar.gz "$tmp/tool_1.2.3.orig.tar.gz"
run "renamed file without --asset-name is refused" 1 "$tmp/tool_1.2.3.orig.tar.gz"

echo
echo "== tampering and missing checksums (expect exit 1) =="

reset_sums
printf '%s  tool-x86_64-linux.tar.gz\n' "$BAD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"
run "checksum mismatch" 1 "$PAYLOAD"

reset_sums
printf '%s\n' "$BAD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"
run "bare hash mismatch" 1 "$PAYLOAD"

reset_sums
run "no checksum published at all (fail-closed)" 1 "$PAYLOAD"

reset_sums
printf '%s  some-other-file.tar.gz\n' "$GOOD_HASH" > "$rel/SHA256SUMS"
run "checksum list does not mention our asset" 1 "$PAYLOAD"

# A suffix match would wrongly accept "notthetool-x86_64-linux.tar.gz".
reset_sums
printf '%s  notthetool-x86_64-linux.tar.gz\n' "$GOOD_HASH" > "$rel/SHA256SUMS"
run "similar-but-different filename is not matched" 1 "$PAYLOAD"

reset_sums
printf '%s  tool-x86_64-linux.tar.gz\n' "$GOOD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"
run "file does not exist locally" 1 "$rel/no-such-file.tar.gz"

echo
echo "== build provenance =="

# checksum is valid for every case below; only the provenance answer changes.
reset_sums
printf '%s  tool-x86_64-linux.tar.gz\n' "$GOOD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"

STUB_ATTESTATION=none run "no provenance, not required -> checksum is enough" 0 "$PAYLOAD"
STUB_ATTESTATION=ok   run "provenance present and valid" 0 "$PAYLOAD"
STUB_ATTESTATION=ok   run "provenance valid, required" 0 --require-attestation "$PAYLOAD"
STUB_ATTESTATION=fail run "provenance present but invalid" 1 "$PAYLOAD"
STUB_ATTESTATION=fail run "provenance invalid, required" 1 --require-attestation "$PAYLOAD"
STUB_ATTESTATION=none run "provenance dropped by upstream while required" 1 --require-attestation "$PAYLOAD"

echo
echo "== either layer may carry the verification =="

reset_sums   # no checksum published at all
STUB_ATTESTATION=ok   run "provenance alone is enough when no checksum exists" 0 "$PAYLOAD"
STUB_ATTESTATION=ok   run "provenance alone, attestation required" 0 --require-attestation "$PAYLOAD"
STUB_ATTESTATION=ok   run "no checksum while --require-checksum given" 1 --require-checksum "$PAYLOAD"
STUB_ATTESTATION=fail run "no checksum and provenance invalid" 1 "$PAYLOAD"
STUB_ATTESTATION=none run "neither layer available" 1 "$PAYLOAD"

reset_sums
printf '%s  tool-x86_64-linux.tar.gz\n' "$GOOD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"
STUB_ATTESTATION=none run "checksum alone is enough when no provenance exists" 0 --require-checksum "$PAYLOAD"
STUB_ATTESTATION=ok   run "both layers required and both present" 0 --require-checksum --require-attestation "$PAYLOAD"

# Regression: the existence probe must filter on the same predicate type the
# verify will demand. Probing unfiltered made any upstream carrying only the
# auto-generated in-toto release attestation (deno, yt-dlp, zed) fail outright,
# even with no --require-attestation and a perfectly good checksum.
reset_sums
printf '%s  tool-x86_64-linux.tar.gz\n' "$GOOD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"
STUB_ATTESTATION=otherpredicate run "unrelated attestation predicate falls back to checksum" 0 "$PAYLOAD"
STUB_ATTESTATION=otherpredicate run "unrelated predicate while attestation required" 1 --require-attestation "$PAYLOAD"

# A checksum that is present but wrong must fail even when provenance passes.
reset_sums
printf '%s  tool-x86_64-linux.tar.gz\n' "$BAD_HASH" > "$rel/tool-x86_64-linux.tar.gz.sha256"
STUB_ATTESTATION=ok   run "bad checksum is fatal even with valid provenance" 1 "$PAYLOAD"

echo
echo "== OpenPGP signature over the checksum file =="

if ! command -v gpg >/dev/null 2>&1; then
  echo "skip - gpg not installed on this host"
else
  # Two throwaway keys: the one we pin, and an impostor. Generated into their
  # own GNUPGHOME so the host's real keyring is never touched or consulted.
  gnupg="$tmp/gnupg"; mkdir -p "$gnupg"; chmod 700 "$gnupg"
  gpgt() { GNUPGHOME="$gnupg" gpg --batch --no-tty --quiet "$@"; }

  gpgt --passphrase '' --quick-generate-key 'Release Key <release@example.test>' default default never
  gpgt --passphrase '' --quick-generate-key 'Impostor <impostor@example.test>'    default default never

  fpr_of() { gpgt --with-colons --list-keys "$1" | awk -F: '/^fpr:/{print $10; exit}'; }
  GOOD_FPR="$(fpr_of release@example.test)"
  EVIL_FPR="$(fpr_of impostor@example.test)"
  OTHER_FPR="0000000000000000000000000000000000000000"

  gpgt --armor --export release@example.test  > "$tmp/release-key.asc"
  gpgt --armor --export impostor@example.test > "$tmp/impostor-key.asc"

  # sign_sums <uid>  -- detached-sign $rel/SHA256SUMS as that identity
  sign_sums() {
    rm -f "$rel/SHA256SUMS.asc"
    gpgt --passphrase '' --pinentry-mode loopback --local-user "$1" \
         --armor --detach-sign --output "$rel/SHA256SUMS.asc" "$rel/SHA256SUMS"
  }

  write_sums() { printf '%s  tool-x86_64-linux.tar.gz\n' "$1" > "$rel/SHA256SUMS"; }

  PIN=(--gpg-key "$tmp/release-key.asc" --gpg-fingerprint "$GOOD_FPR")

  reset_sums; write_sums "$GOOD_HASH"; sign_sums release@example.test
  run "checksum file signed by the pinned key" 0 "${PIN[@]}" "$PAYLOAD"
  run "signed by the pinned key, signature required" 0 "${PIN[@]}" --require-signature "$PAYLOAD"

  # A spaced fingerprint is what gpg prints and what people paste from docs.
  spaced="$(printf '%s' "$GOOD_FPR" | sed 's/..../& /g')"
  run "pinned fingerprint given with spaces" 0 \
      --gpg-key "$tmp/release-key.asc" --gpg-fingerprint "$spaced" --require-signature "$PAYLOAD"

  # Signature made by a key we do not trust: gpg has no public key for it.
  reset_sums; write_sums "$GOOD_HASH"; sign_sums impostor@example.test
  run "checksum file signed by an untrusted key" 1 "${PIN[@]}" "$PAYLOAD"

  # The impostor's key IS importable, but is not the one we pinned -- this is
  # the case a fingerprint pin exists to catch.
  reset_sums; write_sums "$GOOD_HASH"; sign_sums impostor@example.test
  run "valid signature by a key other than the pinned one" 1 \
      --gpg-key "$tmp/impostor-key.asc" --gpg-fingerprint "$GOOD_FPR" "$PAYLOAD"
  run "impostor key pinned to its own fingerprint still is not our key" 0 \
      --gpg-key "$tmp/impostor-key.asc" --gpg-fingerprint "$EVIL_FPR" "$PAYLOAD"

  # Signature that does not cover the checksum file we actually read.
  reset_sums; write_sums "$GOOD_HASH"; sign_sums release@example.test
  printf '%s  tool-x86_64-linux.tar.gz\n' "$GOOD_HASH" >> "$rel/SHA256SUMS"
  run "checksum file altered after signing" 1 "${PIN[@]}" "$PAYLOAD"

  reset_sums; write_sums "$GOOD_HASH"
  run "no signature published, not required -> checksum is enough" 0 "${PIN[@]}" "$PAYLOAD"
  run "no signature published while required (fail-closed)" 1 "${PIN[@]}" --require-signature "$PAYLOAD"

  reset_sums; write_sums "$BAD_HASH"; sign_sums release@example.test
  run "good signature over a checksum that does not match the file" 1 "${PIN[@]}" "$PAYLOAD"

  # Nothing to sign: no checksum file was found at all.
  reset_sums
  run "signature required but no checksum file exists" 1 "${PIN[@]}" --require-signature "$PAYLOAD"

  # A non-default signature asset name.
  reset_sums; write_sums "$GOOD_HASH"; sign_sums release@example.test
  mv "$rel/SHA256SUMS.asc" "$rel/release.sig.asc"
  run "signature asset under a non-default name" 0 \
      "${PIN[@]}" --signature-asset release.sig.asc --require-signature "$PAYLOAD"
  run "default signature name is not found when renamed" 1 \
      "${PIN[@]}" --require-signature "$PAYLOAD"

  echo
  echo "== OpenPGP argument handling (expect exit 1) =="
  reset_sums; write_sums "$GOOD_HASH"; sign_sums release@example.test
  run "--gpg-key without --gpg-fingerprint" 1 --gpg-key "$tmp/release-key.asc" "$PAYLOAD"
  run "--gpg-fingerprint without --gpg-key" 1 --gpg-fingerprint "$GOOD_FPR" "$PAYLOAD"
  run "--require-signature without a pinned key" 1 --require-signature "$PAYLOAD"
  run "truncated fingerprint (key id, not fingerprint)" 1 \
      --gpg-key "$tmp/release-key.asc" --gpg-fingerprint "${GOOD_FPR: -16}" "$PAYLOAD"
  run "missing key file" 1 --gpg-key "$tmp/no-such-key.asc" --gpg-fingerprint "$OTHER_FPR" "$PAYLOAD"
fi

echo
echo "== argument handling (expect exit 1) =="

run "no file given" 1
run "repo without owner/name" 1 --repo tool "$PAYLOAD"
run "unknown option" 1 --nonsense "$PAYLOAD"
run "two files at once" 1 "$PAYLOAD" "$PAYLOAD"

echo
echo "-------------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
