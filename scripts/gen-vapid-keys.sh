#!/usr/bin/env bash
# Generates the VAPID key pair of Web Push (courier) and prints the secret as the YAML block to paste into the vault
# file (make vault-edit F=k8s_secrets_vault.yml). Nothing is written to disk. Same format as
# `go run ./cmd/courierctl vapid`: P-256, base64url without padding (private 32 bytes, public 65 bytes uncompressed).
#
#   scripts/gen-vapid-keys.sh | pbcopy        # macOS: keep the values out of the terminal and its history
#
# The PUBLIC key is not a secret: it is printed as a comment, put it in mm-deploy as VAPID_PUBLIC_KEY of the
# courier and courier-worker Applications. Make the pair ONCE: a new pair makes every browser subscription useless
# (users must turn push on again).
set -euo pipefail
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

der=$(mktemp)
trap 'rm -f "$der"' EXIT
openssl ecparam -name prime256v1 -genkey -noout -outform DER 2>/dev/null >"$der"

# ECPrivateKey DER of P-256: 7 bytes of header, the 32 byte scalar, ..., the 65 byte point at the end.
size=$(wc -c <"$der" | tr -d ' ')
[ "$size" -eq 121 ] || { echo "unexpected key size $size" >&2; exit 1; }
private=$(dd if="$der" bs=1 skip=7 count=32 2>/dev/null | b64url)
public=$(dd if="$der" bs=1 skip=$((size - 65)) count=65 2>/dev/null | b64url)

echo "# Add under vault_k8s_secrets: in k8s_secrets_vault.yml"
echo "# Public key (not a secret): VAPID_PUBLIC_KEY=$public  -> mm-deploy, courier and courier-worker"
echo "  application-courier-vapid:"
echo "    private-key: \"$private\""
