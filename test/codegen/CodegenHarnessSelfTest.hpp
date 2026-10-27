#pragma once

// Self-tests for the codegen .mlir harness (CodegenIsolatedTest.hpp +
// CheckPatterns.hpp). The harness is the code under test here: each case
// writes a tiny scratch fixture whose verdict is known, runs it through
// CodegenIsolatedTest::runCodegenTest (or verifyPatterns directly), and
// asserts the harness REJECTS it. Each case fails while the harness defect it
// names is present and passes once the harness is fixed.
//
// Only subprocess emit modes (-emit=mlir) are used, so no JIT runs in-process.
//
//   SD-21  runSubprocessTest reads ecoc's exit code and never checks it: a
//          fixture with only CHECK-NOT patterns passes even when ecoc rejects
//          the input; a `not %ecoc` fixture passes even when ecoc exits 0.
//   SD-5   only `// CHECK*` directives and only the first RUN line are read:
//          a fixture asserting through `--check-prefix=FWD` (`// FWD:`) or
//          through a second RUN line checks nothing.
//   Test gap (plans/review-bug-list-fixes.md, CHECK order): CHECK and CHECK-DAG are both
//          order-insensitive, so out-of-order output passes.

#include "CodegenIsolatedTest.hpp"
#include "../TestSuite.hpp"

#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <system_error>

#if !defined(_WIN32)
#include <unistd.h>
#endif

namespace CodegenHarnessSelfTest {

// Write `content` to a fresh scratch fixture and return its path.
inline std::string writeScratchFixture(const std::string& name,
                                       const std::string& content) {
    namespace fs = std::filesystem;
#if !defined(_WIN32)
    const std::string pid = std::to_string(::getpid());
#else
    const std::string pid = "0";
#endif
    fs::path dir = fs::temp_directory_path() / ("eco-codegen-harness-selftest-" + pid);
    fs::create_directories(dir);
    fs::path p = dir / name;
    std::ofstream out(p);
    out << content;
    return p.string();
}

// The harness must reject `content`; throw (= this self-test fails) if it
// accepts it.
inline void expectHarnessRejects(const std::string& tag, const std::string& name,
                                 const std::string& content) {
    std::string path = writeScratchFixture(name, content);
    bool rejected = false;
    try {
        CodegenIsolatedTest::runCodegenTest(path);
    } catch (const std::exception&) {
        rejected = true;
    }
    std::error_code ec;
    std::filesystem::remove(path, ec);
    std::filesystem::remove(std::filesystem::path(path).parent_path(), ec);  // only if empty
    if (!rejected) {
        throw std::runtime_error(tag + ": codegen harness ACCEPTED fixture " + name +
                                 " that must fail");
    }
}

// SD-21: ecoc cannot parse this input and exits 1; the only directive is a
// CHECK-NOT that trivially holds on the error text. The harness passes it.
inline Testing::TestCase testSD21NonZeroExitWithOnlyCheckNot(
    "SD-21: subprocess fixture whose ecoc run fails (exit != 0) is rejected", [] {
        expectHarnessRejects("SD-21", "sd21_nonzero_exit_check_not.mlir",
                             "// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s\n"
                             "module {\n"
                             "  this is not valid mlir\n"
                             "}\n"
                             "// CHECK-NOT: eco.this_op_does_not_exist\n");
    });

// SD-21 (other direction): `not %ecoc` promises a non-zero exit, but ecoc
// accepts this valid module and exits 0. The harness passes it.
inline Testing::TestCase testSD21NotEcocExitZero(
    "SD-21: `not %ecoc` fixture whose ecoc run succeeds (exit 0) is rejected", [] {
        expectHarnessRejects("SD-21", "sd21_not_ecoc_exit_zero.mlir",
                             "// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s\n"
                             "module {\n"
                             "}\n"
                             "// CHECK-NOT: eco.this_op_does_not_exist\n");
    });

// SD-5: the fixture's only assertion is a custom-prefix directive that can
// never match. The harness ignores `// FWD:` and passes it.
inline Testing::TestCase testSD5CustomCheckPrefixIgnored(
    "SD-5: failing --check-prefix=FWD directive is not ignored", [] {
        expectHarnessRejects("SD-5", "sd5_custom_prefix.mlir",
                             "// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s --check-prefix=FWD\n"
                             "module {\n"
                             "}\n"
                             "// FWD: sd5-this-text-never-appears-in-ecoc-output\n");
    });

// SD-5: the first RUN line's CHECK holds; the SECOND RUN line's directive
// can never match. The harness runs only the first RUN line and passes it.
inline Testing::TestCase testSD5SecondRunLineIgnored(
    "SD-5: failing second RUN line is not ignored", [] {
        expectHarnessRejects("SD-5", "sd5_second_run_line.mlir",
                             "// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s\n"
                             "// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s --check-prefix=LEG2\n"
                             "module {\n"
                             "}\n"
                             "// CHECK: module\n"
                             "// LEG2: sd5-this-text-never-appears-in-ecoc-output\n");
    });

// Test gap "CHECK-DAG adds no ordering meaning": CHECK lines are matched
// order-insensitively, so output in the opposite order passes. (This hides a
// real failure today: arithmetic_int_minmax.mlir's MIN_INT / -1 line prints a
// garbage value, but its expected text appears on an earlier output line.)
inline Testing::TestCase testCheckOrderEnforced(
    "CHECK-order gap: CHECK lines must match in written order", [] {
        auto patterns = eco_test::extractCheckPatterns("// CHECK: second\n"
                                                       "// CHECK: first\n");
        std::string err = eco_test::verifyPatterns("first\nsecond\n", patterns);
        if (err.empty()) {
            throw std::runtime_error(
                "CHECK-order gap: harness accepted CHECK lines matched out of order");
        }
    });

// Test gap: a CHECK-DAG group must lie between the surrounding CHECK matches
// (FileCheck semantics). Here the DAG line's text only occurs BEFORE the
// preceding CHECK's match, so FileCheck rejects it; the harness accepts it.
inline Testing::TestCase testCheckDagBoundedByChecks(
    "CHECK-DAG gap: CHECK-DAG matches must fall between surrounding CHECKs", [] {
        auto patterns = eco_test::extractCheckPatterns("// CHECK: begin\n"
                                                       "// CHECK-DAG: dag_item\n"
                                                       "// CHECK: end\n");
        std::string err = eco_test::verifyPatterns("dag_item\nbegin\nend\n", patterns);
        if (err.empty()) {
            throw std::runtime_error(
                "CHECK-DAG gap: harness accepted a CHECK-DAG match outside its CHECK block");
        }
    });

inline void registerCodegenHarnessSelfTests(Testing::TestSuite& suite) {
    suite.add(testSD21NonZeroExitWithOnlyCheckNot);
    suite.add(testSD21NotEcocExitZero);
    suite.add(testSD5CustomCheckPrefixIgnored);
    suite.add(testSD5SecondRunLineIgnored);
    suite.add(testCheckOrderEnforced);
    suite.add(testCheckDagBoundedByChecks);
}

}  // namespace CodegenHarnessSelfTest
