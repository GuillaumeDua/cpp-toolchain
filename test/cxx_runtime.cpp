// Compiled once per detected standard (-std=c++NN).
// Scope: NOT to test that the standard's features work — the compiler already guarantees that.
// Only to produce a binary that:
//   (a) dynamically links the C++ runtime (a NEEDED libstdc++/libc++),
//   (b) runs on the `runtime` image, resolving those symbols.
// This is what --auto-remove / --allow-downgrades can break.
//
// Deliberately C++98-clean, so the same payload compiles under every standard the compiler exposes.
// (No emplace_back, no range-based for, no %zu).

#include <string>
#include <vector>
#include <cstddef>
#include <cstdio>

#if defined(_LIBCPP_VERSION)
#  define STDLIB_NAME "libc++"
#  define STDLIB_VER  _LIBCPP_VERSION
#elif defined(__GLIBCXX__)
#  define STDLIB_NAME "libstdc++"
#  define STDLIB_VER  __GLIBCXX__
#else
#  error "Unknown C++ standard library"
#endif

// Out-of-line library calls so the runtime .so is a genuine NEEDED dependency, not inlined away.
// std::string/std::vector suffice: they pull versioned symbols and are stable across every standard, past and future.
int main() {
    std::vector<std::string> v;
    v.push_back(std::string("toolchain"));
    v.push_back(std::string("check"));

    std::string joined;
    for (std::size_t i = 0; i < v.size(); ++i) joined += v[i];

    std::printf(
        "stdlib=%s ver=%ld cxx=%ldL len=%lu\n",
        STDLIB_NAME,
        (long)STDLIB_VER,
        (long)__cplusplus,
        (unsigned long)joined.size()
    );
    return joined.empty() ? 1 : 0;
}
