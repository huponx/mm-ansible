#!/usr/bin/env bash
# Generates new values for the identity and gatekeeper secrets and prints them as the YAML block to paste
# into the vault file (make vault-edit F=k8s_secrets_vault.yml). Nothing is written to disk.
#
#   scripts/gen-identity-secrets.sh | pbcopy        # macOS: keep the values out of the terminal and its history
#
# Secrets: identity-signing-key (EC P-256 PEM), identity-mfa-key, gatekeeper-session, identity-admin (temporary
# password of the first admin, read by the identity setup Job; it must be changed at the first sign in) and
# gatekeeper-client (client secret of gatekeeper, set on the client by the same Job) and dictionary-client
# (client secret of dictionary, which calls identity on behalf of the user) and courier-client (client secret of
# courier, which resolves users and registers its permissions with identity). The VAPID key of Web Push is made apart:
# `go run ./cmd/courierctl vapid` in courier (README of courier, "Browser notifications").
# Run it again only to ROTATE: new MFA keys must be PREPENDED to the old ones (README, "Identity and gatekeeper secrets").
set -euo pipefail
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

key=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null)
mfa="k1:$(openssl rand -base64 32)"
session="k1:$(openssl rand -base64 32)"
admin=$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n')
client=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
dict_client=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
courier_client=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')

echo "# Add under vault_k8s_secrets: in k8s_secrets_vault.yml (kid k1, set IDENTITY_SIGNING_KEY_ID in mm-deploy to match)"
echo "  application-identity-signing-key:"
echo "    signing.pem: |"
printf '%s\n' "$key" | sed 's/^/      /'
echo "  application-identity-mfa-key:"
echo "    keys: \"$mfa\""
echo "  application-gatekeeper-session:"
echo "    keys: \"$session\""
echo "  application-identity-admin:"
echo "    password: \"$admin\"    # temporary: the first admin must change it; remove it from the vault after the first sign in"
echo "  application-gatekeeper-client:"
echo "    secret: \"$client\""
echo "  application-dictionary-client:"
echo "    secret: \"$dict_client\""
echo "  application-courier-client:"
echo "    secret: \"$courier_client\""
