#!/bin/sh
# Fix legacy benchmark-config.env: |interface=.../24} or PREFIX="24}" -> Aeron AsciiNumberFormatException.
# Run after cp to benchmarks-dist/scripts/config. No "set -eu" (CRLF from Windows zip breaks dash on "set").
f="${1:-}"
[ -n "$f" ] && [ -f "$f" ] || exit 0
sed -i -E 's#/([0-9]+)\}+#/\1#g' "$f" || true
sed -i -E 's/(AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=")([0-9]+)\}"/\1\2"/g' "$f" || true
sed -i -E 's/(AERON_ECHO_UDP_INTERFACE_PREFIX_LENGTH=)([0-9]+)\}/\1\2/g' "$f" || true
