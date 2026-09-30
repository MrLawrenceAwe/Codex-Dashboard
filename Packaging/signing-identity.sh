#!/bin/zsh
set -euo pipefail

# Keep local builds tied to one certificate, rather than each build's code hash.
# A caller can supply an existing development/distribution identity instead.
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo 'SIGNING_IDENTITY must be a certificate identity; ad-hoc signing loses Keychain approval after rebuilds.' >&2
    exit 2
  fi
  printf '%s\n' "$SIGNING_IDENTITY"
  exit 0
fi

CERTIFICATE_NAME='Codex Dashboard Local Development'
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
find_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN" \
    | awk -v name="$CERTIFICATE_NAME" '$0 ~ "\"" name "\"$" && $0 !~ /\(/ { print $2; exit }'
}

IDENTITY="$(find_identity)"
if [[ -n "$IDENTITY" ]]; then
  printf '%s\n' "$IDENTITY"
  exit 0
fi

# Do not replace an expired/untrusted certificate: existing Keychain approvals
# refer to its identity. Repair it or explicitly select another identity.
if security find-certificate -c "$CERTIFICATE_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "The existing $CERTIFICATE_NAME certificate is not a valid signing identity. Repair its code-signing trust or set SIGNING_IDENTITY." >&2
  exit 1
fi

umask 077
SIGNING_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-dashboard-signing.XXXXXX")"
trap 'rm -rf "$SIGNING_TEMP"' EXIT
printf 'Creating %s in the login Keychain…\n' "$CERTIFICATE_NAME" >&2
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -subj "/CN=$CERTIFICATE_NAME/" \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=critical,codeSigning' \
  -keyout "$SIGNING_TEMP/key.pem" -out "$SIGNING_TEMP/certificate.pem" 2>/dev/null
# security import expects the traditional RSA encoding rather than OpenSSL 3's
# default PKCS#8 PEM output.
openssl rsa -in "$SIGNING_TEMP/key.pem" -traditional \
  -out "$SIGNING_TEMP/import-key.pem" 2>/dev/null
# Only codesign gets access to this key. Temporary unencrypted key material is
# confined to this private directory and removed on every exit.
security import "$SIGNING_TEMP/import-key.pem" -k "$KEYCHAIN" -t priv -f openssl \
  -x -T /usr/bin/codesign >&2
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" \
  "$SIGNING_TEMP/certificate.pem" >&2
IDENTITY="$(find_identity)"
if [[ -z "$IDENTITY" ]]; then
  echo "Could not resolve $CERTIFICATE_NAME after importing it." >&2
  exit 1
fi
printf '%s\n' "$IDENTITY"
