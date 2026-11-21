#!/usr/bin/env bash
# Generates new values for the identity and gatekeeper secrets and prints them as the YAML block to paste
# into the vault file (make vault-edit F=k8s_secrets_vault.yml). Nothing is written to disk.
#
#   scripts/gen-identity-secrets.sh | pbcopy        # macOS: keep the values out of the terminal and its history
#
# Secrets: identity-signing-key (EC P-256 PEM), identity-mfa-key, gatekeeper-session. The client secret of
# gatekeeper (gatekeeper-client) is printed once by `identityctl client create`, it is not generated here.
# Run it again only to ROTATE: new MFA keys must be PREPENDED to the old ones (README, "Identity and gatekeeper secrets").
set -euo pipefail
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

key=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null)
mfa="k1:$(openssl rand -base64 32)"
session="k1:$(openssl rand -base64 32)"

echo "# Add under vault_k8s_secrets: in k8s_secrets_vault.yml (kid k1, set IDENTITY_SIGNING_KEY_ID in mm-deploy to match)"
echo "  application-identity-signing-key:"
echo "    signing.pem: |"
printf '%s\n' "$key" | sed 's/^/      /'
echo "  application-identity-mfa-key:"
echo "    keys: \"$mfa\""
echo "  application-gatekeeper-session:"
echo "    keys: \"$session\""
