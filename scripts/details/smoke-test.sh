#!/usr/bin/env bash
# Minimal image smoke test - compiles and runs a C++23 hello world with both default compilers.
# Runs inside the image under test (release-candidate-check.yml bind-mounts this directory and
# executes this file), so it must only rely on what the dev stage ships.
#
# std::print rather than iostream on purpose: it is a C++23 library feature, so this fails when
# -std=c++23 is accepted but the standard library behind it is not what the manifest claims.
#
# TODO: widen the matrix - per-compiler-version coverage, the cross triplets, cmake, clang-tidy
#   and the vcpkg/conan paths are all unexercised here.
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
