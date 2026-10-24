// CheckPatterns.hpp — shared CHECK-directive parsing + matching for
// every codegen / E2E test harness in this repo.
//
// Supported directives (base prefix "// CHECK:" shown; the Elm hosts
// pass "-- CHECK:"-style prefixes, the codegen harnesses pass the
// RUN line's --check-prefix(es), and the variants are derived from
// whatever base is passed, e.g. "-- CHECK-MLIR:" → "-- CHECK-MLIR-DAG:"):
//   - CHECK:       pattern must appear in the output.
//   - CHECK-NOT:   pattern must NOT appear anywhere in the output. (Stricter
//                  than FileCheck, which only searches between the
//                  surrounding positive matches.)
//   - CHECK-DAG:   a run of consecutive CHECK-DAGs matches in any order,
//                  without overlapping, between the surrounding matches.
//   - CHECK-LABEL: splits the output into blocks: every label is matched
//                  first, in order, and the directives after a label must
//                  match between it and the next label.
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
// Ordering (CheckOrder): verifyPatterns defaults to CheckOrder::Ordered,
// FileCheck's semantics: each CHECK matches at or after the end of the
// previous match, DAG groups and LABEL blocks as above. The codegen and
// bf-codegen harnesses use it. CheckOrder::Unordered is the pre-2026-10-24
// behaviour, kept for the Elm E2E hosts (ElmE2ETestBase, aot_e2e_main),
// whose fixtures were never audited for order: every positive pattern only
// has to appear somewhere, and DAG / LABEL are plain CHECKs.
//
// History: before 2026-08-02 only CHECK: / CHECK-NOT: were parsed and
// every other variant was SILENTLY SKIPPED — ~30 fixtures for the
// deleted unboxed-agg passes "passed" while asserting nothing (borrow
// design doc §2.4; tier-1 plan U-T1.3.0). Unrecognised CHECK-* variants
// are now a hard parse error so that failure mode cannot recur. Until
// 2026-10-24 matching was order-insensitive everywhere (review-bug-list
// test gap "CHECK-DAG"), which hid arithmetic_int_minmax.mlir's MIN_INT bug.
//
// FileCheck-style {{regex}} markers inside any pattern are honoured:
// everything outside {{...}} matches literally, the body inside is
// inlined verbatim into the compiled regex. Patterns without {{ }}
// use fast substring search.
//
// Four sites use this header (CodegenIsolatedTest, BFCodegenTest,
// ElmE2ETestBase, aot_e2e_main).

#pragma once

#include <algorithm>
#include <cstring>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
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

    // Which directive introduced a positive pattern (ordering only; see
    // verifyPatterns). Negated patterns are always Kind::Check.
    enum class Kind { Check, Dag, Label };

    std::string pattern;
    bool negated;
    std::vector<Continuation> continuations;
    Kind kind = Kind::Check;
};

/// How verifyPatterns treats the written order of positive directives
/// (see the header comment).
enum class CheckOrder { Ordered, Unordered };

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

namespace detail {

/// One directive prefix family: "// CHECK:" plus the variants derived from it.
struct PrefixFamily {
    std::string check, notP, dag, same, next, label, bareBase;

    PrefixFamily(const char* checkPrefix, const char* checkNotPrefix)
        : check(checkPrefix), notP(checkNotPrefix),
          dag(variantPrefix(checkPrefix, "DAG")),
          same(variantPrefix(checkPrefix, "SAME")),
          next(variantPrefix(checkPrefix, "NEXT")),
          label(variantPrefix(checkPrefix, "LABEL")),
          bareBase(checkPrefix) {
        // For the unknown-variant guard: "// CHECK" (base prefix minus colon).
        if (!bareBase.empty() && bareBase.back() == ':') bareBase.pop_back();
    }
};

inline std::vector<CheckPattern> extractCheckPatternsImpl(
        const std::string& content, const std::vector<PrefixFamily>& families) {
    enum class D { None, Not, Same, Next, Dag, Label, Check };

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
        D d = D::None;
        std::string p;
        std::string unknown;  // an unrecognised `<prefix>-WORD:` seen on this line
        for (const PrefixFamily& f : families) {
            size_t pos;
            if ((pos = line.find(f.notP)) != std::string::npos) {
                d = D::Not; p = grab(line, pos, f.notP.size());
            } else if ((pos = line.find(f.same)) != std::string::npos) {
                d = D::Same; p = grab(line, pos, f.same.size());
            } else if ((pos = line.find(f.next)) != std::string::npos) {
                d = D::Next; p = grab(line, pos, f.next.size());
            } else if ((pos = line.find(f.dag)) != std::string::npos) {
                d = D::Dag; p = grab(line, pos, f.dag.size());
            } else if ((pos = line.find(f.label)) != std::string::npos) {
                d = D::Label; p = grab(line, pos, f.label.size());
            } else if ((pos = line.find(f.check)) != std::string::npos) {
                d = D::Check; p = grab(line, pos, f.check.size());
            } else if ((pos = line.find(f.bareBase + "-")) != std::string::npos &&
                       unknown.empty()) {
                // An unrecognised CHECK-* variant (e.g. CHECK-COUNT-3:).
                // Guard: only flag it when it looks like a directive (has a
                // colon after the variant word) — otherwise prose mentioning
                // "CHECK-..." in comments would trip this. The `MLIR` word
                // family ("-- CHECK-MLIR:" / "-- CHECK-MLIR-NOT:") is a
                // separate directive family parsed by a second
                // extractCheckPatterns pass (ElmE2ETestBase) — exempt.
                size_t colon = line.find(':', pos + f.bareBase.size());
                size_t wordEnd = line.find_first_of(" \t", pos + f.bareBase.size());
                if (colon != std::string::npos &&
                    (wordEnd == std::string::npos || colon < wordEnd)) {
                    size_t wordStart = pos + f.bareBase.size() + 1;
                    std::string word = line.substr(wordStart, colon - wordStart);
                    if (word.rfind("MLIR", 0) != 0) {
                        unknown = line.substr(pos, colon - pos + 1);
                    }
                }
            }
            if (d != D::None) break;
        }
        if (d == D::None) {
            if (!unknown.empty()) {
                throw std::runtime_error(
                    "CheckPatterns: unsupported CHECK variant in test file: " + unknown +
                    " (supported: CHECK, CHECK-NOT, CHECK-DAG, CHECK-SAME, "
                    "CHECK-NEXT, CHECK-LABEL)");
            }
            continue;
        }
        if (p.empty()) continue;
        switch (d) {
        case D::Not:
            patterns.push_back({std::move(p), /*negated=*/true, {}});
            lastPositive = -1;
            break;
        case D::Same:
        case D::Next:
            if (lastPositive >= 0) {
                patterns[lastPositive].continuations.push_back(
                    {d == D::Same ? CheckPattern::Continuation::Kind::SameLine
                                  : CheckPattern::Continuation::Kind::NextLine,
                     std::move(p)});
            } else {
                patterns.push_back({std::move(p), /*negated=*/false, {}});
                lastPositive = static_cast<int>(patterns.size()) - 1;
            }
            break;
        default:
            patterns.push_back({std::move(p), /*negated=*/false, {},
                                d == D::Dag     ? CheckPattern::Kind::Dag
                                : d == D::Label ? CheckPattern::Kind::Label
                                                : CheckPattern::Kind::Check});
            lastPositive = static_cast<int>(patterns.size()) - 1;
            break;
        }
    }
    return patterns;
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
    return detail::extractCheckPatternsImpl(content, {{checkPrefix, checkNotPrefix}});
}

/**
 * FileCheck's --check-prefixes for `//` fixtures: the directives of every
 * named prefix (e.g. {"CHECK", "JIT"} → `// CHECK:`, `// JIT-NOT:`, ...), in
 * file order. A line is attributed to the first prefix that names it.
 */
inline std::vector<CheckPattern> extractCheckPatternsForPrefixes(
        const std::string& content, const std::vector<std::string>& prefixes) {
    std::vector<detail::PrefixFamily> families;
    for (const std::string& name : prefixes) {
        const std::string check = "// " + name + ":";
        const std::string notP = "// " + name + "-NOT:";
        families.emplace_back(check.c_str(), notP.c_str());
    }
    return detail::extractCheckPatternsImpl(content, families);
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

namespace detail {

/**
 * First match of `pattern` in text[from, to): [begin, end) offsets, or
 * nullopt. Honours {{regex}} (`^`, `\b` see the text before `from`);
 * malformed regex falls back to substring search.
 */
inline std::optional<std::pair<size_t, size_t>> findPatternInRange(
        const std::string& text, size_t from, size_t to, const std::string& pattern) {
    if (to > text.size()) to = text.size();
    if (from > to) return std::nullopt;
    auto substrFind = [&]() -> std::optional<std::pair<size_t, size_t>> {
        size_t p = text.find(pattern, from);
        if (p == std::string::npos || p + pattern.size() > to) return std::nullopt;
        return std::make_pair(p, p + pattern.size());
    };
    auto reStr = buildCheckRegexStr(pattern);
    if (!reStr) {
        return substrFind();
    }
    try {
        std::regex re(*reStr);
        std::smatch m;
        // Line by line, as in FileCheck: a match never spans lines, and `^` /
        // `$` anchor at line boundaries.
        size_t lineBegin = from;
        while (lineBegin > 0 && text[lineBegin - 1] != '\n') --lineBegin;
        for (size_t start = from; start <= to;) {
            size_t nl = text.find('\n', start);
            size_t end = std::min(nl == std::string::npos ? text.size() : nl, to);
            auto flags = start == lineBegin
                ? std::regex_constants::match_default
                : (std::regex_constants::match_prev_avail | std::regex_constants::match_not_bol);
            if (std::regex_search(text.cbegin() + start, text.cbegin() + end, m, re, flags)) {
                size_t b = static_cast<size_t>(m[0].first - text.cbegin());
                return std::make_pair(b, b + static_cast<size_t>(m.length(0)));
            }
            if (nl == std::string::npos || nl >= to) break;
            start = lineBegin = nl + 1;
        }
        return std::nullopt;
    } catch (const std::regex_error&) {
        return substrFind();
    }
}

/// 1-based line number of offset `pos` (for diagnostics).
inline size_t lineNumberAt(const std::string& text, size_t pos) {
    size_t n = 1;
    for (size_t i = 0; i < pos && i < text.size(); ++i)
        if (text[i] == '\n') ++n;
    return n;
}

/**
 * Ordered match of a base pattern + its SAME/NEXT chain inside
 * text[from, to): as in FileCheck, the FIRST base occurrence, whose
 * continuations must then all hold (no retry at a later occurrence).
 * Returns [base begin, end of the last constraint's match).
 */
inline std::optional<std::pair<size_t, size_t>> findGroupInRange(
        const std::string& text, size_t from, size_t to, const CheckPattern& cp) {
    auto lineEnd = [&](size_t pos) {
        size_t e = text.find('\n', pos);
        return std::min(e == std::string::npos ? text.size() : e, to);
    };
    auto base = findPatternInRange(text, from, to, cp.pattern);
    if (!base) return std::nullopt;
    size_t curEnd = base->second;
    for (const auto& cont : cp.continuations) {
        std::optional<std::pair<size_t, size_t>> m;
        if (cont.kind == CheckPattern::Continuation::Kind::SameLine) {
            m = findPatternInRange(text, curEnd, lineEnd(curEnd), cont.pattern);
        } else {  // NextLine
            size_t nl = text.find('\n', curEnd);
            if (nl != std::string::npos && nl + 1 < to)
                m = findPatternInRange(text, nl + 1, lineEnd(nl + 1), cont.pattern);
        }
        if (!m) return std::nullopt;
        curEnd = m->second;
    }
    return std::make_pair(base->first, curEnd);
}

inline std::string describeGroup(const CheckPattern& cp) {
    std::string d = cp.pattern;
    if (!cp.continuations.empty())
        d += " (with " + std::to_string(cp.continuations.size()) +
             " CHECK-SAME/CHECK-NEXT continuation(s))";
    return d;
}

/// Pre-2026-10-24 semantics (CheckOrder::Unordered): presence only.
inline std::string verifyPatternsUnordered(const std::string& output,
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
            lines = splitLines(output);
            linesSplit = true;
        }
        if (!groupMatches(lines, cp)) {
            return "Missing pattern: " + describeGroup(cp);
        }
    }
    return "";  // Success
}

/// FileCheck semantics (CheckOrder::Ordered); see the header comment.
inline std::string verifyPatternsOrdered(const std::string& output,
                                         const std::vector<CheckPattern>& patterns) {
    // CHECK-NOT: absent from the whole output.
    for (const auto& cp : patterns) {
        if (cp.negated && findPatternInRange(output, 0, output.size(), cp.pattern)) {
            return "Unexpected pattern (CHECK-NOT): " + cp.pattern;
        }
    }

    // Why a positive group found nothing in [from, to): it is missing
    // altogether, or it only occurs outside the window the order allows.
    auto missing = [&](const CheckPattern& cp, size_t from, size_t to,
                       const char* what) -> std::string {
        std::string msg = "Missing pattern" + std::string(what) + ": " + describeGroup(cp);
        if (auto base = findPatternInRange(output, from, to, cp.pattern)) {
            msg += " -- the first match of the base pattern (output line " +
                   std::to_string(lineNumberAt(output, base->first)) +
                   ") fails a CHECK-SAME/CHECK-NEXT continuation";
        } else if (auto any = findGroupInRange(output, 0, output.size(), cp)) {
            msg += " -- out of order: it only matches at output line " +
                   std::to_string(lineNumberAt(output, any->first)) +
                   ", outside the allowed window (output lines " +
                   std::to_string(lineNumberAt(output, from)) + ".." +
                   std::to_string(lineNumberAt(output, to)) + ")";
        }
        return msg;
    };

    // CHECK-LABEL: matched first, in order; they split the output into blocks.
    std::vector<size_t> labelIdx;
    std::vector<std::pair<size_t, size_t>> labelMatch;
    size_t cur = 0;
    for (size_t i = 0; i < patterns.size(); ++i) {
        const CheckPattern& cp = patterns[i];
        if (cp.negated || cp.kind != CheckPattern::Kind::Label) continue;
        auto m = findGroupInRange(output, cur, output.size(), cp);
        if (!m) return missing(cp, cur, output.size(), " (CHECK-LABEL)");
        labelIdx.push_back(i);
        labelMatch.push_back(*m);
        cur = m->second;
    }

    // Directives [first, last) must match in output [from, to).
    auto matchBlock = [&](size_t first, size_t last, size_t from,
                          size_t to) -> std::string {
        size_t cursor = from;
        for (size_t i = first; i < last;) {
            const CheckPattern& cp = patterns[i];
            if (cp.negated) { ++i; continue; }
            if (cp.kind != CheckPattern::Kind::Dag) {
                auto m = findGroupInRange(output, cursor, to, cp);
                if (!m) return missing(cp, cursor, to, "");
                cursor = m->second;
                ++i;
                continue;
            }
            // A run of CHECK-DAGs (CHECK-NOTs inside it are global, above):
            // each from `cursor`, never overlapping another of the run.
            std::vector<std::pair<size_t, size_t>> taken;
            size_t groupEnd = cursor;
            for (; i < last && (patterns[i].negated ||
                                patterns[i].kind == CheckPattern::Kind::Dag);
                 ++i) {
                const CheckPattern& dag = patterns[i];
                if (dag.negated) continue;
                size_t s = cursor;
                std::optional<std::pair<size_t, size_t>> m;
                while ((m = findGroupInRange(output, s, to, dag))) {
                    bool overlaps = false;
                    for (const auto& t : taken)
                        if (m->first < t.second && t.first < m->second) overlaps = true;
                    if (!overlaps) break;
                    s = m->first + 1;
                }
                if (!m) return missing(dag, cursor, to, " (CHECK-DAG)");
                taken.push_back(*m);
                groupEnd = std::max(groupEnd, m->second);
            }
            cursor = groupEnd;
        }
        return "";
    };

    size_t firstBlockEnd = labelIdx.empty() ? patterns.size() : labelIdx[0];
    size_t firstBlockTo = labelMatch.empty() ? output.size() : labelMatch[0].first;
    std::string err = matchBlock(0, firstBlockEnd, 0, firstBlockTo);
    if (!err.empty()) return err;
    for (size_t k = 0; k < labelIdx.size(); ++k) {
        size_t last = k + 1 < labelIdx.size() ? labelIdx[k + 1] : patterns.size();
        size_t to = k + 1 < labelMatch.size() ? labelMatch[k + 1].first : output.size();
        err = matchBlock(labelIdx[k] + 1, last, labelMatch[k].second, to);
        if (!err.empty()) return err + " (in the block of CHECK-LABEL: " +
                                 patterns[labelIdx[k]].pattern + ")";
    }
    return "";  // Success
}

}  // namespace detail

/**
 * Verify that the output satisfies every CHECK directive: positive
 * patterns must appear (with any SAME/NEXT continuations satisfied by
 * a single base match; in written order under CheckOrder::Ordered),
 * negated ones must not appear anywhere. Returns empty string on
 * success, or a single diagnostic identifying the offending pattern on
 * failure.
 */
inline std::string verifyPatterns(const std::string& output,
                                   const std::vector<CheckPattern>& patterns,
                                   CheckOrder order = CheckOrder::Ordered) {
    return order == CheckOrder::Ordered ? detail::verifyPatternsOrdered(output, patterns)
                                        : detail::verifyPatternsUnordered(output, patterns);
}

// ----------------------------------------------------------------------------
// Process directives (plans/eco-system-library.md Phase 1 step 8c). Each must
// start a line so prose mentioning a directive is not picked up.
//
//   -- EXIT: <n>     expected process exit status. The JIT harness enforces it
//                    (default 0) for checkProcessOutput suites, and a test that
//                    has it runs in process-output mode in any suite (Phase 7:
//                    EcoSystem* stress programs that end with System.exit); the
//                    AOT runner enforces it only when present.
//   -- STDIN: <text> text fed to the program's stdin through a pipe. One space
//                    after the colon is a separator; `\n`, `\t` and `\\` are
//                    unescaped; repeated lines are concatenated in order.
//   -- LINUX-ONLY: <reason>
//                    the test needs Linux (e.g. /dev/full); every harness skips
//                    it, printing the reason, on any other host. The JS runner
//                    reads it too (test/scripts/run-js-e2e.js).
// ----------------------------------------------------------------------------

namespace detail {
// Calls fn(rest) for every line that starts with `marker`, where `rest` is the
// text after the marker with a trailing '\r' removed.
template <class Fn>
inline void forEachDirectiveLine(const std::string& content, const char* marker, Fn fn) {
    const size_t mlen = std::strlen(marker);
    size_t pos = 0;
    while (pos < content.size()) {
        size_t eol = content.find('\n', pos);
        if (eol == std::string::npos) eol = content.size();
        if (eol - pos >= mlen && content.compare(pos, mlen, marker) == 0) {
            std::string rest = content.substr(pos + mlen, eol - pos - mlen);
            if (!rest.empty() && rest.back() == '\r') rest.pop_back();
            fn(rest);
        }
        pos = eol + 1;
    }
}
} // namespace detail

/// The `-- EXIT: <n>` directive (first occurrence), or nullopt when absent.
/// A malformed value throws std::runtime_error so a typo cannot silently
/// disable the check.
inline std::optional<int> extractExitDirective(const std::string& content,
                                               const char* marker = "-- EXIT:") {
    std::optional<int> result;
    detail::forEachDirectiveLine(content, marker, [&](const std::string& rest) {
        if (result) return;
        std::string t = trimCheckPattern(rest);
        size_t used = 0;
        int v = 0;
        try {
            v = std::stoi(t, &used);
        } catch (...) {
            used = 0;
        }
        if (t.empty() || used != t.size()) {
            throw std::runtime_error("malformed EXIT directive: '" + rest + "'");
        }
        result = v;
    });
    return result;
}

/// The concatenated `-- STDIN:` text, or nullopt when there is no directive.
inline std::optional<std::string> extractStdinDirective(const std::string& content,
                                                        const char* marker = "-- STDIN:") {
    std::optional<std::string> result;
    detail::forEachDirectiveLine(content, marker, [&](const std::string& rest) {
        std::string text = (!rest.empty() && rest[0] == ' ') ? rest.substr(1) : rest;
        std::string out;
        for (size_t i = 0; i < text.size(); i++) {
            if (text[i] == '\\' && i + 1 < text.size()) {
                char n = text[i + 1];
                if (n == 'n') { out += '\n'; i++; continue; }
                if (n == 't') { out += '\t'; i++; continue; }
                if (n == '\\') { out += '\\'; i++; continue; }
            }
            out += text[i];
        }
        if (!result) result = std::string();
        *result += out;
    });
    return result;
}

/// Why the test cannot run on this host: the `-- LINUX-ONLY:` reason (or
/// "Linux only" when it gives none) on a host that is not Linux, nullopt
/// otherwise.
inline std::optional<std::string> hostSkipReason(const std::string& content) {
#if defined(__linux__)
    (void)content;
    return std::nullopt;
#else
    std::optional<std::string> result;
    detail::forEachDirectiveLine(content, "-- LINUX-ONLY:", [&](const std::string& rest) {
        if (result) return;
        std::string t = trimCheckPattern(rest);
        bool blank = t.find_first_not_of(" \t") == std::string::npos;
        result = "LINUX-ONLY: " + (blank ? std::string("no reason given") : t);
    });
    return result;
#endif
}

} // namespace eco_test
