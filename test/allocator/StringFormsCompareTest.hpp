/**
 * HEAP_025: StringOps::equal / StringOps::compare across all six String heap
 * forms, and the rule that neither flattens nor allocates.
 */

#ifndef STRING_FORMS_COMPARE_TEST_HPP
#define STRING_FORMS_COMPARE_TEST_HPP

#include "../TestSuite.hpp"

void registerStringFormsCompareTests(Testing::TestSuite& suite);

#endif // STRING_FORMS_COMPARE_TEST_HPP
