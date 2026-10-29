/**
 * Regression tests for GC-safety defects found in the runtime review (cpp-review-bugs.md, "High
 * severity"): each forces a collection at the exact point the defect needs.
 */

#ifndef GC_SAFETY_REPRO_TEST_HPP
#define GC_SAFETY_REPRO_TEST_HPP

#include "../TestSuite.hpp"

void registerGcSafetyReproTests(Testing::TestSuite& suite);

#endif // GC_SAFETY_REPRO_TEST_HPP
