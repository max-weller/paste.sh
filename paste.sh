#!/bin/bash
# Client for paste.sh - https://paste.sh/client
#
# Usage:
#   Send clipboard:
#     $ paste.sh
#   Send output of command:
#     $ foo 2&>1 | paste.sh
#   File:
#     $ paste.sh some-file
#
#   Print paste:
#     $ paste.sh 'https://paste.sh/xxxxx#xxxx'
#     (You need to quote or escape the URL due to the #)

HOST=https://paste.sh


die() {
  echo "${1}" >&2
  exit ${2:-1}
}

# Generate x bytes of randomness, then base64 encode and make URL safe
randbase64() {
  openssl rand -base64 -rand /dev/urandom $1 2>/dev/null | tr '+/' '-_'
}

# Write data to a temp file and open it on given fd to avoid passing on command
# line
tmpfd() {
  tmp="$(mktemp)"
  echo "$1" > "$tmp" || die "Unable to write to temp. file."
  eval "exec $2<$tmp"
  rm -f $tmp || die "Unable to remove temp. file. Aborting to avoid key leak"
}


openssl version &>/dev/null || die "Please install OpenSSL" 127
curl --version &>/dev/null || die "Please install curl" 127

# Try to use memory if we can (Linux, probably) and the user hasn't set TMPDIR
if [ -z "$TMPDIR" -a -w /dev/shm ]; then
  export TMPDIR=/dev/shm
fi

# What are we doing?
cmd=
arg=
if [[ $# -gt 0 ]]; then
  if [[ ${1:0:8} = https:// ]]; then
    # We have a URL, grab it
    echo TODO: Implement reading
    exit 0
  elif [ -e "${1}" -o "${1}" == "-" ]; then
    # File (also handle '-', via cat)
    if [ "${1}" != '-' -a "$(stat -c %s "${1}")" -gt $[640 * 1024] ]; then
      die "${1}: File too big"
    fi
    cmd="cat --"
    arg="${1}"
  else
    echo "$1: No such file and not a https URL"
    exit 1
  fi
elif ! [ -t 0 ]; then  # Something piped to us, read it
  cmd=cat
  arg=-
else  # No input, read clipboard
  if [[ $(uname) = Darwin ]]; then
    cmd=pbpaste
  else
    cmd=xsel
    arg=-o
  fi
fi

# Generate ID, get server key
id="$(randbase64 6)"
# TODO: Retry if the error is the id is already taken
serverkey=$(curl -sS "$HOST/new?id=$id")
# Yes, this is essentially another salt
[[ -n ${serverkey} ]] || die "Failed getting server salt"

# Generate client key (nothing stopping you changing this, this seemed like a
# reasonable trade off; 144 bits)
clientkey="$(randbase64 18)"

# The full key includes some extras for more entropy. (OpenSSL adds a salt too,
# so the ID isn't really needed, but won't hurt).
tmpfd "${id}${serverkey}${clientkey}${HOST}" 3

file=$(mktemp)
trap 'rm -f "${file}"' EXIT
# It would be nice to use PBKDF2 or just more iterations of the key derivation
# function, but the OpenSSL command line tool can't do that.
$cmd "$arg" \
  | openssl enc -aes-256-cbc -md sha512 -pass fd:3 -base64 > "${file}"

# Get rid of the temp. file once server supports HTTP/1.1 chunked uploads correctly.
curl -sS -0 -H "X-Server-Key: ${serverkey}" -T "${file}" "$HOST/${id}" \
  || die "Failed pasting data"

echo "$HOST/${id}#${clientkey}"