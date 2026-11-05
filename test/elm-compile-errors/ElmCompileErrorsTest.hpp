#pragma once
#include "../ElmE2ETestBase.hpp"

// Programs the compiler must reject: each carries a `-- COMPILE-ERROR: <what>` line and CHECK lines
// matched against the error report (CheckPatterns.hpp). They cover the front end's error paths,
// which the run tests never reach: type errors, canonicalization and pattern errors.
namespace ElmCompileErrorsTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmCompileErrorsTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-compile-errors", "Elm Compile Errors E2E", "elm-compile-errors/");
}

}  // namespace ElmCompileErrorsTest
