// The functional half of image verification: proof the toolchain actually works.
//
// Use both C++23 language and library features.

#include <expected>
#include <numeric>
#include <print>
#include <string>
#include <vector>

namespace
{
    // Deducing this (P0847)
    struct counter
    {
        int value = 0;

        constexpr auto bumped(this counter self) -> counter
        {
            return {self.value + 1};
        }
    };

    // constexpr std::vector (P0784, P1004): allocation during constant evaluation.
    consteval auto sum_to(int n) -> int
    {
        auto values = std::vector<int>{};
        for (int i = 1; i <= n; ++i)
            values.push_back(i);
        return std::accumulate(values.begin(), values.end(), 0);
    }

    auto checked(int value) -> std::expected<int, std::string>
    {
        if (value > 0)
            return value;
        return std::unexpected{"not positive"};
    }
}

auto main() -> int
{
    constexpr static auto total = sum_to(10);
    static_assert(total == 55, "constexpr std::vector did not evaluate at compile time");

    constexpr static auto bumped = counter{41}.bumped();
    static_assert(bumped.value == 42, "deducing this did not evaluate at compile time");

    const auto parsed = checked(bumped.value);
    if (not parsed.has_value())
    {
        std::print("cxx23-fail {}\n", parsed.error());
        return 1;
    }

    // The marker the runner greps for.
    // Asserting on output rather than exit status alone catches a binary that links, runs and silently does nothing.
    std::print("cxx23-ok cplusplus={} sum={} value={}\n", __cplusplus, total, *parsed); // WIP: total is useless here, since it's already checked with a static_assert
    return 0;
}
