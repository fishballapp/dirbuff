# Sourced by build.sh. `open_signing_keychain` imports the team's Developer ID certificate
# (MAC_NATIVE_APP_APPLE_CERTIFICATE, a base64 .p12, and its password, both loaded by varlock from
# 1Password) into a keychain that exists for this build alone, then unsets both, so nothing the
# build runs afterwards sees them. The .p12 goes to `security import` through a pipe and never
# touches disk. The keychain is deleted when the shell exits, however it exits.
#
# It is safe on a developer's Mac and beside other builds running at once: it adds its keychain to
# the user's search list (Xcode looks for the identity there) and takes only that entry off again,
# reading the list as it is at that moment; it never writes back an older copy of the list, and
# never changes the default keychain. codesign is pointed at the keychain itself (SIGNING_KEYCHAIN,
# for --keychain), so the build can only sign with this certificate.
#
# `security` takes the passwords as arguments (-p, -P) and has no other way; another process of the
# same user could read them while that command runs. CI does the same. Accepted.
#
# Every array expansion is `${a[@]+"${a[@]}"}`: an empty array is an unbound variable under `set -u`
# in macOS's /bin/bash 3.2.

# The user's keychain search list, one path per line.
read_search_list() {
  local entry
  while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry#\"}"
    printf '%s\n' "${entry%\"}"
  done < <(security list-keychains -d user)
}

# Sets the search list to its current entries, less $1, plus $2 when given.
edit_search_list() {
  local drop="$1" add="${2:-}" entry
  local entries=()
  while IFS= read -r entry; do
    [[ -n "$entry" && "$entry" != "$drop" ]] && entries+=("$entry")
  done < <(read_search_list)
  [[ -n "$add" ]] && entries+=("$add")
  security list-keychains -d user -s ${entries[@]+"${entries[@]}"}
}

open_signing_keychain() {
  if [[ -z "${MAC_NATIVE_APP_APPLE_CERTIFICATE:-}" || -z "${MAC_NATIVE_APP_APPLE_CERTIFICATE_PASSWORD:-}" ]]; then
    echo "Error: the Developer ID certificate (MAC_NATIVE_APP_APPLE_CERTIFICATE and its password) is missing." >&2
    echo "Run it through varlock, which loads it from 1Password: pnpm -F @dirbuff/mac with-secrets -- ./build.sh" >&2
    return 1
  fi

  # The real path (/private/var/…), the form the search list reports it in.
  SIGNING_KEYCHAIN_DIR="$(cd "$(mktemp -d -t dirbuff-signing)" && pwd -P)"
  SIGNING_KEYCHAIN="$SIGNING_KEYCHAIN_DIR/signing.keychain-db"
  trap close_signing_keychain EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local password
  password="$(openssl rand -hex 16)"
  security create-keychain -p "$password" "$SIGNING_KEYCHAIN"
  security set-keychain-settings -lut 3600 "$SIGNING_KEYCHAIN"
  security unlock-keychain -p "$password" "$SIGNING_KEYCHAIN"
  printf '%s' "$MAC_NATIVE_APP_APPLE_CERTIFICATE" | base64 -d |
    security import /dev/stdin -k "$SIGNING_KEYCHAIN" -f pkcs12 -t agg \
      -P "$MAC_NATIVE_APP_APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
  unset MAC_NATIVE_APP_APPLE_CERTIFICATE MAC_NATIVE_APP_APPLE_CERTIFICATE_PASSWORD
  # Lets codesign use the key without asking; it lists the key's attributes, not the key.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" \
    "$SIGNING_KEYCHAIN" >/dev/null
  edit_search_list "" "$SIGNING_KEYCHAIN"
}

# Each step runs whatever the one before did: the keychain holding the key goes first.
close_signing_keychain() {
  security delete-keychain "$SIGNING_KEYCHAIN" 2>/dev/null || true
  rm -rf "$SIGNING_KEYCHAIN_DIR" || true
  # delete-keychain takes it off the search list too; this covers a delete that failed.
  edit_search_list "$SIGNING_KEYCHAIN" || true
}
