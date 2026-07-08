/**
 * Differential tests: UTF-8 (ASCII) String forms must behave identically to
 * the default UTF-16 forms across every StringOps operation.
 */

#ifndef UTF8_STRING_TEST_HPP
#define UTF8_STRING_TEST_HPP

#include "../TestSuite.hpp"

void registerUtf8StringTests(Testing::TestSuite& suite);

#endif // UTF8_STRING_TEST_HPP
