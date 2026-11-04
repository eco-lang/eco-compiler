#ifndef ECO_REGEX_HPP
#define ECO_REGEX_HPP

// A C++ interface to regular expressions over Elm strings, which nothing calls.
//
// elm/regex's kernel functions are the `extern "C"` exports in RegexExports.cpp, which keep their
// compiled patterns in a side table of byte-wise `srell::regex` objects and include nothing from this
// header. The declarations here are a separate design, built on `srell::u16regex` (SRELL's `char16_t`
// engine) and a `std::shared_ptr` handle. It is compiled into `ElmKernel_Regex` but has no callers, and
// most of it is a stub: `fromStringWith` always returns `Nothing`, and `findAtMost`, `replaceAtMost` and
// `splitAtMost` ignore the regex. Its behaviour is not what Elm programs get.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <functional>
#include <limits>
#include <memory>
// SRELL (vendored) rather than <regex>: std::basic_regex<char16_t> is only an
// extension under libstdc++, and libc++'s <regex> provides no regex_traits for
// char16_t. SRELL's u16regex matches UTF-16 text.
#include "srell.hpp"

namespace Elm::Kernel::Regex {

/// A compiled regular expression together with the source and options it was compiled from.
///
/// A plain struct: nothing checks that `pattern` was compiled from `patternStr` with these options. A
/// default-constructed `Regex` holds a default-constructed `srell::u16regex`.
struct Regex {
    srell::u16regex pattern;
    std::vector<u16> patternStr;
    bool caseInsensitive = false;
    bool multiline = false;

    Regex() = default;
};

/// A shared handle on a `Regex`. The functions below treat a null handle as matching nothing.
using RegexPtr = std::shared_ptr<Regex>;

/// The match count that stands for no limit in this interface. Unused; the live `Regex.infinity` export
/// returns a `double` positive infinity instead.
constexpr i64 infinity = std::numeric_limits<i64>::max();

/// Returns a regex compiled from `.^`, intended never to match. If compiling throws, the returned
/// `Regex` keeps a default-constructed `pattern`.
RegexPtr never();

/// Compiles the Elm string at `pattern` with the given options and returns `Nothing`, whether or not it
/// compiled: this interface has no way to put a `RegexPtr` in a heap value. `pattern` must point to an Elm
/// string object.
HPointer fromStringWith(void* pattern, bool caseInsensitive, bool multiline);

/// Returns whether `regex` matches anywhere in the Elm string at `str`, matched as UTF-16. Returns false
/// for a null `regex` or when matching throws.
bool contains(RegexPtr regex, void* str);

/// Returns the empty list, whatever the arguments. A stub.
HPointer findAtMost(i64 n, RegexPtr regex, void* str);

/// A function that is given a `Match` record and returns the replacement string. `replaceAtMost` never
/// calls it.
using ReplacerFn = std::function<HPointer(HPointer)>;

/// Returns `str` itself as an HPointer, unchanged, whatever the other arguments. A stub.
HPointer replaceAtMost(i64 n, RegexPtr regex, ReplacerFn replacer, void* str);

/// Returns a one-element list holding `str`, whatever the other arguments. A stub, and a GC point.
HPointer splitAtMost(i64 n, RegexPtr regex, void* str);

} // namespace Elm::Kernel::Regex

#endif // ECO_REGEX_HPP
