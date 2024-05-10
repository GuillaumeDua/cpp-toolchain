# cpp-toolchain

Up-to-date C++ toolchain docker for development.

Available here on [DockerHub](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-dev/general).

---

## Packages

- Compilers: GNU-G++, LLVM-Clang++
- Build: CMake Bazel Build2 make/Unix-makefile ninja ccache
- Dependency-management: vcpkg conan
- Analysis: valgrind cppcheck iwyu
- Versioning: git subversion
- Debug: gdb lldb
- Documentation: doxygen graphviz
- Shells: bash zsh
- Tools: python3, jq, ripgrep

## Arguments

- GCC_VERSIONS='>=11' : all|latest|>=(number)|(space-separated-numbers...)
- LLVM_VERSIONS='>=14' : all|latest|>=(number)|(space-separated-numbers...)
- integrate_Bazel : set to y to install
- integrate_Build2 : set to y to install

## Misc

Remote access using ssh (openssh-server, rsync) on port 22
