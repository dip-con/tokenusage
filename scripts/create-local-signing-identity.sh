#!/usr/bin/env bash
set -euo pipefail

# Creates a self-signed code-signing identity for local builds. Ad hoc builds are trusted by the
# Keychain only through their cdhash, which changes on every build, so each reinstall made every
# saved account ask for the login password again. A build signed with this identity keeps one
# designated requirement (bundle id + this certificate), and "Always Allow" survives reinstalls.

NAME="${TOKEN_USAGE_LOCAL_SIGN_IDENTITY:-tokenusage-local-codesign}"
KEYCHAIN="${HOME:?}/Library/Keychains/login.keychain-db"

fail() {
    printf 'create-local-signing-identity: error: %s\n' "$*" >&2
    exit 1
}

if /usr/bin/security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    printf 'create-local-signing-identity: %s already exists\n' "$NAME"
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
chmod 700 "$WORK_DIR"

cat >"$WORK_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# The system LibreSSL writes a PKCS#12 that `security import` accepts; OpenSSL 3 defaults do not.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK_DIR/openssl.cnf" \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" 2>/dev/null \
    || fail "could not create the certificate"
PASSPHRASE="$(/usr/bin/uuidgen)"
/usr/bin/openssl pkcs12 -export -name "$NAME" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -out "$WORK_DIR/identity.p12" -passout "pass:$PASSPHRASE" \
    || fail "could not package the identity"
# -T lets codesign use the private key without a Keychain prompt on every build.
/usr/bin/security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" \
    -P "$PASSPHRASE" -T /usr/bin/codesign >/dev/null \
    || fail "could not import the identity into the login keychain"

printf 'create-local-signing-identity: created %s in the login keychain\n' "$NAME"
