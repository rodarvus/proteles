#!/usr/bin/env bash
#
# Create a stable, self-signed code-signing identity ("Proteles Dev") in
# the login keychain, used to sign local Release builds of the app.
#
# Why: unsigned / ad-hoc builds have no stable code identity, so macOS
# treats every build (and even every launch) as a different application and
# re-prompts for Keychain access even after you click "Always Allow". A
# stable signing identity gives the app a stable *designated requirement*,
# so the keychain remembers your decision across rebuilds.
#
# Run once. Idempotent — does nothing if the identity already exists.
# No Apple Developer account required. The certificate is self-signed and
# only used for local development (it is NOT for distribution; releases get
# a real Developer ID).

set -euo pipefail

IDENTITY_NAME="Proteles Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASSWORD="proteles"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Code-signing identity '$IDENTITY_NAME' already exists — nothing to do."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -days 3650 -config "$work/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export -name "$IDENTITY_NAME" \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/identity.p12" -passout "pass:$P12_PASSWORD" >/dev/null 2>&1

# -A lets any application use the private key without a prompt, so codesign
# can sign without nagging. (This is only the signing key, not app secrets.)
echo "Importing into the login keychain…"
security import "$work/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -A >/dev/null 2>&1

echo "Done. Available code-signing identities:"
security find-identity -v -p codesigning | grep "$IDENTITY_NAME" || {
    echo "WARNING: '$IDENTITY_NAME' did not register as a code-signing identity." >&2
    exit 1
}
