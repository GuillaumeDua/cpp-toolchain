#!/bin/bash
set -uo pipefail

CXX="${1:-g++}"

die() { echo "error: $*" >&2; exit 1; }

command -v "$CXX" >/dev/null 2>&1 \
  || die "compiler '$CXX' not found in PATH"

echo | "$CXX" -xc++ -E - >/dev/null 2>&1 \
  || die "'$CXX' exists but failed to run as a C++ compiler"

# Try Clang-style discovery: valid values are quoted in the -std error.
err=$(echo | "$CXX" -std=blah -xc++ -c - 2>&1)
stds=$(printf '%s\n' "$err" \
  | grep -oP "(?<=')(c|gnu)\+\+\w+(?=')" | grep -v gnu | sort -uV)

# Fall back to GCC-style: scrape -v --help.
if [ -z "$stds" ]; then
  stds=$("$CXX" -v --help 2>&1 \
    | grep -oP '(?<=-std=)(c\+\+\w+)' | grep -v gnu | sort -uV)
fi

[ -n "$stds" ] \
  || die "could not discover any C++ standards for '$CXX'"

found=0
for std in $stds; do
  val=$(echo | "$CXX" -std="$std" -xc++ -dM -E - 2>/dev/null \
    | grep -oP '(?<=__cplusplus )\d+')
  if [ -n "$val" ]; then
    echo "$std -> __cplusplus=$val"
    found=$((found + 1))
  fi
done

[ "$found" -gt 0 ] \
  || die "'$CXX' accepted no C++ standard (none produced __cplusplus)"

exit 0