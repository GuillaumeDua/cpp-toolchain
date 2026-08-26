// The image validation gate's payload, compiled once per detected standard (-std=c++NN).
// What it is for, and why it is this small, is in docs/IMAGES_VALIDATION.md.
//
// Two constraints an edit must not break:
//   - C++98-clean, so one payload compiles under every standard the compiler exposes.
//     No emplace_back, no range-based for, no %zu.
//   - every library call stays out of line, so the runtime .so remains a genuine NEEDED
//     dependency rather than being inlined away.

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

// std::string and std::vector suffice: they pull versioned symbols and are stable across every standard.
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
