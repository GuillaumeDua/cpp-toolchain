// Compiled in `build`, executed in `runtime` - the one test that justifies the runtime stage.
//
// runtime exists so a binary produced by `build` can be shipped in a smaller image, which depends on
// the PPA libstdc++ surviving both the --auto-remove purge and the snapshot dist-upgrade downgrade
// dance in the Dockerfile's realignment block. Nothing has ever checked that it does.
//
// `int main(){}` would only prove libc is present. This deliberately reaches for the parts of the
// runtime that a version skew actually breaks:
//   - a std::string past the small-string-optimisation boundary, so the allocator and the
//     out-of-line libstdc++ symbols are involved rather than an inline header-only path
//   - a thrown and caught exception, which pulls in the exception tables and libgcc_s's unwinder
// A libstdc++ older than the one this was linked against fails here, not at load time.

#include <cstdio>
#include <stdexcept>
#include <string>

namespace
{
    struct too_long : std::runtime_error
    {
        using std::runtime_error::runtime_error;
    };

    auto stretch(std::string::size_type length) -> std::string
    {
        // Well past the SSO buffer of every mainstream libstdc++, so this really allocates.
        auto text = std::string(length, 'x');
        if (text.size() > 128)
            throw too_long{text.substr(0, 8)};
        return text;
    }
}

auto main() -> int
{
    auto caught = false;
    try
    {
        static_cast<void>(stretch(4096));
    }
    catch (const too_long& error)
    {
        caught = std::string{error.what()} == "xxxxxxxx";
    }

    if (not caught)
        return 1;
    if (stretch(64).size() != 64)
        return 1;

    // std::puts rather than std::print for the marker: the point of this binary is the libstdc++
    // string and unwinder path above, and the marker itself should not add a dependency of its own.
    std::puts("runtime-abi-ok");
    return 0;
}
