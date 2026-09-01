#!/usr/bin/env bash
# Minimal image smoke test - compiles and runs a C++23 hello world with both default compilers.
# Runs inside the image under test (release-candidate-check.yml bind-mounts this directory and
# executes this file), so it must only rely on what the dev stage ships.
#
# std::print rather than iostream on purpose: it is a C++23 library feature, so this fails when
# -std=c++23 is accepted but the standard library behind it is not what the manifest claims.
#
# The compiler matrix belongs to the build gate: cxx-runtime.sh covers every installed major against
# every standard it exposes, plus the cross triplets. What this adds is the dev stage, which no
# validate stage derives from, reached by digest once it is published.
#
# TODO: cmake, clang-tidy and the vcpkg/conan paths are unexercised anywhere. A validate stage is the
#   place for them, so a pull request fails before an rc exists.
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

cat > "${tmp}/hello.cpp" <<'CPP'
#include <print>

int main() { std::print("hello from C++{}\n", __cplusplus); }
CPP

for cxx in g++ clang++; do
  echo "== ${cxx}: $(${cxx} --version | head -1)"
  "${cxx}" -std=c++23 "${tmp}/hello.cpp" -o "${tmp}/hello-${cxx}"
  "${tmp}/hello-${cxx}"
done

echo "smoke test passed"
