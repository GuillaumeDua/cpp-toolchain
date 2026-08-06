// Compiled once per detected standard (-std=c++NN).
// Scope: NOT to test that the standard's features work — the compiler already guarantees that.
// Only to produce a binary that:
//   (a) dynamically links the C++ runtime (a NEEDED libstdc++/libc++),
//   (b) runs on the `runtime` image, resolving those symbols.
// This is what --auto-remove / --allow-downgrades can break.

#include <string>
#include <vector>
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
    v.emplace_back("toolchain");
    v.emplace_back("check");

    std::string joined;
    for (auto& s : v) joined += s;

    std::printf(
        "stdlib=%s ver=%ld cxx=%ldL len=%zu\n",
        STDLIB_NAME,
        (long)STDLIB_VER,
        (long)__cplusplus,
        joined.size()
    );
    return joined.empty() ? 1 : 0;
}

/*
TODO:

# requirement/expectation: the binary MUST declare libstdc++ or libc++ as NEEDED.
# must prevent static linkage, as it'd defeat the purpose of the check
if ! readelf -d "$bin" | grep -qE 'NEEDED.*lib(stdc\+\+|c\+\+)\.so'; then
    echo "FAIL: C++ runtime linked statically — image runtime check is meaningless"
    exit 1
fi

*/