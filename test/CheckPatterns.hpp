// CheckPatterns.hpp — shared CHECK-directive parsing + matching for
// every codegen / E2E test harness in this repo.
//
// Supported directives (base prefix "// CHECK:" shown; the Elm hosts
// pass "-- CHECK:"-style prefixes and the variants are derived from
// whatever base is passed, e.g. "-- CHECK-MLIR:" → "-- CHECK-MLIR-DAG:"):
//   - CHECK:       pattern must appear somewhere in the output.
//   - CHECK-NOT:   pattern must NOT appear anywhere.
//   - CHECK-DAG:   alias of CHECK. (This harness is order-insensitive
//                  everywhere, so DAG's "unordered within a block"
//                  semantics collapse to plain presence.)
//   - CHECK-LABEL: alias of CHECK. (No block partitioning here; the
//                  label line is simply asserted present.)
//   - CHECK-SAME:  continuation of the nearest preceding positive
//                  directive: must match on the SAME output line, at or
//                  after the end of that directive's match, in written
//                  order across consecutive CHECK-SAMEs.
//   - CHECK-NEXT:  continuation of the nearest preceding positive
//                  directive: must match on the line immediately after
//                  the line the previous constraint matched on; each
//                  further CHECK-NEXT advances one more line.
// A SAME/NEXT with no preceding positive directive (file start, or
// following a CHECK-NOT) degrades to a standalone positive pattern.
//
// History: before 2026-08-02 only CHECK: / CHECK-NOT: were parsed and
// every other variant was SILENTLY SKIPPED — ~30 fixtures for the
// deleted unboxed-agg passes "passed" while asserting nothing (borrow
// design doc §2.4; tier-1 plan U-T1.3.0). Unrecognised CHECK-* variants
// are now a hard parse error so that failure mode cannot recur.
//
// FileCheck-style {{regex}} markers inside any pattern are honoured:
// everything outside {{...}} matches literally, the body inside is
// inlined verbatim into the compiled regex. Patterns without {{ }}
// use fast substring search.
//
// Four sites use this header (CodegenIsolatedTest, BFCodegenTest,
// ElmE2ETestBase, aot_e2e_main).

#pragma once

#include <cstring>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace eco_test {

/**
 * One CHECK directive parsed out of a test file, plus any SAME/NEXT
 * continuation constraints attached to it. A positive pattern with no
 * continuations means "appears somewhere in the output"; with
 * continuations, some single base match must additionally satisfy each
 * continuation (same-line-after / next-line) in order. Negative
 * (negated=true) patterns must not appear anywhere and never carry
 * continuations.
 */
struct CheckPattern {
    struct Continuation {
        enum class Kind { SameLine, NextLine };
        Kind kind;
        std::string pattern;
    };

    std::string pattern;
    bool negated;
    std::vector<Continuation> continuations;
};

/**
 * Strip leading and trailing whitespace from a CHECK / CHECK-NOT
 * pattern body.
 */
inline std::string trimCheckPattern(std::string pattern) {
    size_t start = pattern.find_first_not_of(" \t");
    if (start != std::string::npos) {
        pattern = pattern.substr(start);
    }
    size_t end = pattern.find_last_not_of(" \t\r\n");
    if (end != std::string::npos) {
        pattern = pattern.substr(0, end + 1);
    }
    return pattern;
}

namespace detail {

/**
 * Derive a variant prefix from the base check prefix by inserting
 * `-WORD` before the trailing colon: "// CHECK:" + "DAG" → "// CHECK-DAG:".
 * Falls back to appending if the base has no trailing colon.
 */
inline std::string variantPrefix(const char* checkPrefix, const char* word) {
    std::string base(checkPrefix);
    if (!base.empty() && base.back() == ':') {
        base.pop_back();
    }
    base.push_back('-');
    base.append(word);
    base.push_back(':');
    return base;
}

/**
 * Compile a CHECK pattern into a regex string: literal segments are
 * escaped, `{{...}}` bodies are inlined verbatim. Returns std::nullopt
 * for patterns without any `{{` (callers should use the substring fast
 * path).
 */
inline std::optional<std::string> buildCheckRegexStr(const std::string& pattern) {
    if (pattern.find("{{") == std::string::npos) {
        return std::nullopt;
    }
    static constexpr const char kRegexSpecials[] = R"(.^$|?*+()[]{}\)";
    std::string re;
    re.reserve(pattern.size() * 2);
    size_t pos = 0;
    auto appendLiteral = [&](size_t end) {
        for (size_t i = pos; i < end; ++i) {
            char c = pattern[i];
            if (std::strchr(kRegexSpecials, c)) re.push_back('\\');
            re.push_back(c);
        }
    };
    while (pos < pattern.size()) {
        size_t open = pattern.find("{{", pos);
        if (open == std::string::npos) {
            appendLiteral(pattern.size());
            break;
        }
        appendLiteral(open);
        size_t close = pattern.find("}}", open + 2);
        if (close == std::string::npos) {
            // Unmatched `{{` — rewind and treat the rest as literal.
            pos = open;
            appendLiteral(pattern.size());
            break;
        }
        re.append(pattern, open + 2, close - open - 2);
        pos = close + 2;
    }
    return re;
}

/**
 * Find the first match of `pattern` in `text` starting at offset
 * `from`. Returns the [begin, end) offsets of the match, or nullopt.
 * Honours {{regex}}; malformed regex falls back to substring search.
 */
inline std::optional<std::pair<size_t, size_t>> findPatternIn(
        const std::string& text, size_t from, const std::string& pattern) {
    if (from > text.size()) {
        return std::nullopt;
    }
    auto substrFind = [&]() -> std::optional<std::pair<size_t, size_t>> {
        size_t p = text.find(pattern, from);
        if (p == std::string::npos) return std::nullopt;
        return std::make_pair(p, p + pattern.size());
    };
    auto reStr = buildCheckRegexStr(pattern);
    if (!reStr) {
        return substrFind();
    }
    try {
        std::regex re(*reStr);
        std::smatch m;
        std::string tail = text.substr(from);
        if (!std::regex_search(tail, m, re)) return std::nullopt;
        return std::make_pair(from + m.position(0),
                              from + m.position(0) + m.length(0));
    } catch (const std::regex_error&) {
        return substrFind();
    }
}

}  // namespace detail

/**
 * Parse CHECK-family lines out of `content`. Variant prefixes
 * (CHECK-NOT / CHECK-DAG / CHECK-SAME / CHECK-NEXT / CHECK-LABEL) are
 * derived from `checkPrefix`; `checkNotPrefix` is kept as an explicit
 * parameter for API stability with the existing call sites. Any other
 * `CHECK-*:` variant derived from the base prefix (e.g. CHECK-COUNT)
 * throws — silent skipping is exactly the vacuous-fixture failure mode
 * this parser previously had.
 */
inline std::vector<CheckPattern> extractCheckPatterns(
        const std::string& content,
        const char* checkPrefix = "// CHECK:",
        const char* checkNotPrefix = "// CHECK-NOT:") {
    const size_t checkLen = std::strlen(checkPrefix);
    const std::string dagPrefix = detail::variantPrefix(checkPrefix, "DAG");
    const std::string samePrefix = detail::variantPrefix(checkPrefix, "SAME");
    const std::string nextPrefix = detail::variantPrefix(checkPrefix, "NEXT");
    const std::string labelPrefix = detail::variantPrefix(checkPrefix, "LABEL");
    // For the unknown-variant guard: "// CHECK" (base prefix minus colon).
    std::string bareBase(checkPrefix);
    if (!bareBase.empty() && bareBase.back() == ':') bareBase.pop_back();

    std::vector<CheckPattern> patterns;
    // Index into `patterns` of the most recent positive directive a
    // SAME/NEXT may attach to; -1 when none (start of file / after NOT).
    int lastPositive = -1;

    auto grab = [](const std::string& line, size_t pos, size_t prefixLen) {
        return trimCheckPattern(line.substr(pos + prefixLen));
    };

    std::istringstream stream(content);
    std::string line;
    while (std::getline(stream, line)) {
        size_t pos;
        if ((pos = line.find(checkNotPrefix)) != std::string::npos) {
            std::string p = grab(line, pos, std::strlen(checkNotPrefix));
            if (!p.empty()) {
                patterns.push_back({std::move(p), /*negated=*/true, {}});
                lastPositive = -1;
            }
        } else if ((pos = line.find(samePrefix)) != std::string::npos) {
            std::string p = grab(line, pos, samePrefix.size());
            if (p.empty()) continue;
            if (lastPositive >= 0) {
                patterns[lastPositive].continuations.push_back(
                    {CheckPattern::Continuation::Kind::SameLine, std::move(p)});
            } else {
                patterns.push_back({std::move(p), /*negated=*/false, {}});
                lastPositive = static_cast<int>(patterns.size()) - 1;
            }
        } else if ((pos = line.find(nextPrefix)) != std::string::npos) {
            std::string p = grab(line, pos, nextPrefix.size());
            if (p.empty()) continue;
            if (lastPositive >= 0) {
                patterns[lastPositive].continuations.push_back(
                    {CheckPattern::Continuation::Kind::NextLine, std::move(p)});
            } else {
                patterns.push_back({std::move(p), /*negated=*/false, {}});
                lastPositive = static_cast<int>(patterns.size()) - 1;
            }
        } else if ((pos = line.find(dagPrefix)) != std::string::npos) {
            std::string p = grab(line, pos, dagPrefix.size());
            if (!p.empty()) {
                patterns.push_back({std::move(p), /*negated=*/false, {}});
                lastPositive = static_cast<int>(patterns.size()) - 1;
            }
        } else if ((pos = line.find(labelPrefix)) != std::string::npos) {
            std::string p = grab(line, pos, labelPrefix.size());
            if (!p.empty()) {
                patterns.push_back({std::move(p), /*negated=*/false, {}});
                lastPositive = static_cast<int>(patterns.size()) - 1;
            }
        } else if ((pos = line.find(checkPrefix)) != std::string::npos) {
            std::string p = grab(line, pos, checkLen);
            if (!p.empty()) {
                patterns.push_back({std::move(p), /*negated=*/false, {}});
                lastPositive = static_cast<int>(patterns.size()) - 1;
            }
        } else if ((pos = line.find(bareBase + "-")) != std::string::npos) {
            // An unrecognised CHECK-* variant (e.g. CHECK-COUNT-3:).
            // Guard: only flag it when it looks like a directive (has a
            // colon after the variant word) — otherwise prose mentioning
            // "CHECK-..." in comments would trip this. The `MLIR` word
            // family ("-- CHECK-MLIR:" / "-- CHECK-MLIR-NOT:") is a
            // separate directive family parsed by a second
            // extractCheckPatterns pass (ElmE2ETestBase) — exempt.
            size_t colon = line.find(':', pos + bareBase.size());
            size_t wordEnd = line.find_first_of(" \t", pos + bareBase.size());
            if (colon != std::string::npos &&
                (wordEnd == std::string::npos || colon < wordEnd)) {
                size_t wordStart = pos + bareBase.size() + 1;
                std::string word = line.substr(wordStart, colon - wordStart);
                if (word.rfind("MLIR", 0) != 0) {
                    throw std::runtime_error(
                        "CheckPatterns: unsupported CHECK variant in test file: " +
                        line.substr(pos, colon - pos + 1) +
                        " (supported: CHECK, CHECK-NOT, CHECK-DAG, CHECK-SAME, "
                        "CHECK-NEXT, CHECK-LABEL)");
                }
            }
        }
    }
    return patterns;
}

/**
 * True iff `output` contains a substring matching `pattern` (ignoring
 * continuations — see verifyPatterns for group matching).
 */
inline bool patternMatches(const std::string& output,
                            const std::string& pattern) {
    auto reStr = detail::buildCheckRegexStr(pattern);
    if (!reStr) {
        return output.find(pattern) != std::string::npos;
    }
    try {
        return std::regex_search(output, std::regex(*reStr));
    } catch (const std::regex_error&) {
        return output.find(pattern) != std::string::npos;
    }
}

namespace detail {

/**
 * Match a base pattern + its SAME/NEXT continuation chain against the
 * output, line-oriented: some occurrence of the base pattern on some
 * line must satisfy every continuation (SAME: same line, at/after the
 * previous constraint's end; NEXT: anywhere on the following line,
 * advancing one line per NEXT).
 */
inline bool groupMatches(const std::vector<std::string>& lines,
                         const CheckPattern& cp) {
    for (size_t i = 0; i < lines.size(); ++i) {
        // Try every occurrence of the base pattern on this line.
        size_t searchFrom = 0;
        while (true) {
            auto base = findPatternIn(lines[i], searchFrom, cp.pattern);
            if (!base) break;
            size_t curLine = i;
            size_t curPos = base->second;
            bool ok = true;
            for (const auto& cont : cp.continuations) {
                if (cont.kind == CheckPattern::Continuation::Kind::SameLine) {
                    auto m = findPatternIn(lines[curLine], curPos, cont.pattern);
                    if (!m) { ok = false; break; }
                    curPos = m->second;
                } else {  // NextLine
                    ++curLine;
                    if (curLine >= lines.size()) { ok = false; break; }
                    auto m = findPatternIn(lines[curLine], 0, cont.pattern);
                    if (!m) { ok = false; break; }
                    curPos = m->second;
                }
            }
            if (ok) return true;
            searchFrom = base->first + 1;
        }
    }
    return false;
}

inline std::vector<std::string> splitLines(const std::string& output) {
    std::vector<std::string> lines;
    std::istringstream stream(output);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        lines.push_back(std::move(line));
    }
    return lines;
}

}  // namespace detail

/**
 * Verify that the output satisfies every CHECK directive: positive
 * patterns must appear (with any SAME/NEXT continuations satisfied by
 * a single base match), negated ones must not appear anywhere. Returns
 * empty string on success, or a single diagnostic identifying the
 * offending pattern on failure.
 */
inline std::string verifyPatterns(const std::string& output,
                                   const std::vector<CheckPattern>& patterns) {
    std::vector<std::string> lines;  // lazily split, only if a group needs it
    bool linesSplit = false;
    for (const auto& cp : patterns) {
        if (cp.negated) {
            if (patternMatches(output, cp.pattern)) {
                return "Unexpected pattern (CHECK-NOT): " + cp.pattern;
            }
            continue;
        }
        if (cp.continuations.empty()) {
            if (!patternMatches(output, cp.pattern)) {
                return "Missing pattern: " + cp.pattern;
            }
            continue;
        }
        if (!linesSplit) {
            lines = detail::splitLines(output);
            linesSplit = true;
        }
        if (!detail::groupMatches(lines, cp)) {
            return "Missing pattern: " + cp.pattern + " (with " +
                   std::to_string(cp.continuations.size()) +
                   " CHECK-SAME/CHECK-NEXT continuation(s))";
        }
    }
    return "";  // Success
}

} // namespace eco_test
