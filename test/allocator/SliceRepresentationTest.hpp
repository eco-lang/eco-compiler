#ifndef SLICE_REPRESENTATION_TEST_HPP
#define SLICE_REPRESENTATION_TEST_HPP

#include "../TestSuite.hpp"
#include "../IsolatedTestRunner.hpp"

// Clean tests (fail via thrown assertion or pass) — safe to run in-process.
void registerSliceRepresentationTests(Testing::TestSuite& suite);

// Crash-risk tests: drive a real GC over a Tag_ByteBufferSlice, which under the
// getObjectSize (F1) bug aborts the process. Added to a fork-isolated suite so
// each abort is reported as a single failed test instead of killing the binary.
void registerSliceCrasherTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);

#endif  // SLICE_REPRESENTATION_TEST_HPP
