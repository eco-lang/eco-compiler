#pragma once
#include "../ElmE2ETestBase.hpp"

// Programs the compiler must reject: each carries a `-- COMPILE-ERROR: <what>` line and one CHECK
// line, the title of the error report (`-- TYPE MISMATCH -`), not its text, so that a reworded
// message does not fail a test that is still rejected for the right reason (CheckPatterns.hpp). They cover the front end's error paths,
// which the run tests never reach: type errors, canonicalization and pattern errors.
namespace ElmCompileErrorsTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmCompileErrorsTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-compile-errors", "Elm Compile Errors E2E", "elm-compile-errors/");
}

}  // namespace ElmCompileErrorsTest
