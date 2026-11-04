#pragma once

// Check counters and CHECK for the small unit-test binaries that do not use the `test` binary's
// framework (eco-system-core-test, elm-kernel-time-test).
//
// CHECK(cond) counts one check and, when `cond` is false, one failure (printed to stderr). The
// binary's main prints the totals and exits non-zero when CoreTest::g_failures is non-zero.
// Header-only; the counters are inline variables shared by every translation unit of the binary.

#include <atomic>
#include <cstdio>
#include <string>

namespace CoreTest {

inline std::atomic<int> g_failures{0};
inline std::atomic<int> g_checks{0};

// Records one failed check with a message (for checks that are not a plain boolean expression).
inline void fail(const char* file, int line, const std::string& what) {
    ++g_checks;
    ++g_failures;
    std::fprintf(stderr, "  FAIL %s:%d: %s\n", file, line, what.c_str());
}

}  // namespace CoreTest

#define CHECK(cond)                                                                \
    do {                                                                           \
        ++::CoreTest::g_checks;                                                    \
        if (!(cond)) {                                                             \
            ++::CoreTest::g_failures;                                              \
            std::fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                          \
    } while (0)

// CHECK with a message describing what was seen.
#define CHECK_MSG(cond, msg)                                                       \
    do {                                                                           \
        if (cond) {                                                                \
            ++::CoreTest::g_checks;                                                \
        } else {                                                                   \
            ::CoreTest::fail(__FILE__, __LINE__, std::string(#cond) + ": " + (msg)); \
        }                                                                          \
    } while (0)
