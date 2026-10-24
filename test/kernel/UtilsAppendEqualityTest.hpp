#ifndef UTILS_APPEND_EQUALITY_TEST_HPP
#define UTILS_APPEND_EQUALITY_TEST_HPP

#include "../TestSuite.hpp"

// SD-17: Elm_Kernel_Utils_append / eco_string_append / eco_list_append over
// every String form and every List spine form (regression guard: the
// polymorphic Utils::append "return first argument" fallback must never be
// reached by an Elm-legal appendable pair).
//
// SD-26 (latent): the merged Empty constant ("") versus a zero-length
// heap-resident String, through each equality / ordering path. No producer
// of a zero-length heap String exists today (HEAP_071), so the tests build one
// directly; the failing cases show which paths do NOT treat it as "".
void registerUtilsAppendEqualityTests(Testing::TestSuite& suite);

#endif  // UTILS_APPEND_EQUALITY_TEST_HPP
