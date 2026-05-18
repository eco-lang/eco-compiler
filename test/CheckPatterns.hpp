// CheckPatterns.hpp — shared CHECK / CHECK-NOT parsing + matching for
// every codegen / E2E test harness in this repo.
//
// Provides:
//   - CheckPattern struct (positive / negated)
//   - trimCheckPattern (whitespace trim)
//   - extractCheckPatterns(content, prefixes) — parameterised on the
//     CHECK / CHECK-NOT line prefix so MLIR tests can use "// CHECK:"
//     and Elm-source tests can use "-- CHECK:" via the same parser.
//   - patternMatches(output, pattern) — FileCheck-style {{regex}}
//     markers inside the pattern are honoured; the rest matches
//     literally. Patterns without {{ }} fall through to fast substring
//     search so existing fixtures pay no overhead.
//   - verifyPatterns(output, patterns) — positive must appear,
//     negated must not; returns empty string on success or a
//     diagnostic on failure.
//
// Three sites use this header (CodegenIsolatedTest, BFCodegenTest,
// ElmE2ETestBase). The dead CodegenTest.hpp still has its own
// pre-CHECK-NOT copy of this logic and is not wired into main.cpp;
// consolidate or delete in a separate cleanup PR.

#pragma once

#include <cstring>
#include <regex>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace eco_test {

/**
 * One CHECK directive parsed out of a test file. Positive (CHECK:)
 * means the pattern must appear somewhere in the output; negative
 * (CHECK-NOT:) means it must NOT appear anywhere. Order is not
 * enforced — matching is "anywhere in output", which is sufficient
 * for our codegen / E2E tests.
 */
struct CheckPattern {
    std::string pattern;
    bool negated;
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

/**
 * Parse CHECK and CHECK-NOT lines out of `content`. We scan for the
 * longer `checkNotPrefix` first because the shorter `checkPrefix` is
 * its prefix and would otherwise swallow it.
 *
 * `checkPrefix` / `checkNotPrefix` differ between language hosts:
 *   - MLIR fixtures use "// CHECK:" / "// CHECK-NOT:"
 *   - Elm fixtures   use "-- CHECK:" / "-- CHECK-NOT:"
 */
inline std::vector<CheckPattern> extractCheckPatterns(
        const std::string& content,
        const char* checkPrefix = "// CHECK:",
        const char* checkNotPrefix = "// CHECK-NOT:") {
    const size_t checkLen = std::strlen(checkPrefix);
    const size_t checkNotLen = std::strlen(checkNotPrefix);

    std::vector<CheckPattern> patterns;
    std::istringstream stream(content);
    std::string line;
    while (std::getline(stream, line)) {
        size_t notPos = line.find(checkNotPrefix);
        if (notPos != std::string::npos) {
            std::string pattern =
                trimCheckPattern(line.substr(notPos + checkNotLen));
            if (!pattern.empty()) {
                patterns.push_back({std::move(pattern), /*negated=*/true});
            }
            continue;
        }
        size_t pos = line.find(checkPrefix);
        if (pos != std::string::npos) {
            std::string pattern =
                trimCheckPattern(line.substr(pos + checkLen));
            if (!pattern.empty()) {
                patterns.push_back({std::move(pattern), /*negated=*/false});
            }
        }
    }
    return patterns;
}

/**
 * True iff `output` contains a substring matching `pattern`.
 *
 * FileCheck-style `{{regex}}` sequences inside `pattern` are honoured:
 * everything outside `{{...}}` is matched literally (with regex
 * specials properly escaped); the body inside `{{...}}` is inlined
 * verbatim into the compiled regex. Patterns with no `{{` short-
 * circuit to a fast `std::string::find` so existing literal-pattern
 * fixtures pay no overhead.
 *
 * Edge cases:
 *   - Unmatched `{{`: the rest of the pattern is treated as literal.
 *   - Malformed regex inside `{{...}}`: `std::regex_error` is caught
 *     and we fall back to substring search on the raw pattern (the
 *     test then fails with a clear "Missing pattern" message).
 */
inline bool patternMatches(const std::string& output,
                            const std::string& pattern) {
    if (pattern.find("{{") == std::string::npos) {
        return output.find(pattern) != std::string::npos;
    }

    // Regex specials that need escaping when emitted into the literal
    // (non-{{...}}) segments of the pattern.
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
    try {
        return std::regex_search(output, std::regex(re));
    } catch (const std::regex_error&) {
        return output.find(pattern) != std::string::npos;
    }
}

/**
 * Verify that the output satisfies every CHECK directive: positive
 * patterns must appear, negated ones must not. Returns empty string
 * on success, or a single diagnostic identifying the offending
 * pattern on failure.
 */
inline std::string verifyPatterns(const std::string& output,
                                   const std::vector<CheckPattern>& patterns) {
    for (const auto& cp : patterns) {
        bool found = patternMatches(output, cp.pattern);
        if (cp.negated && found) {
            return "Unexpected pattern (CHECK-NOT): " + cp.pattern;
        }
        if (!cp.negated && !found) {
            return "Missing pattern: " + cp.pattern;
        }
    }
    return "";  // Success
}

} // namespace eco_test
