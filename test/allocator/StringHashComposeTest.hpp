/**
 * Tests for value-hash definition v4 and the String hashes given at build (HEAP_088,
 * plans/hash-reuse-explicit-vs-cached.md B5a-B5c).
 */

#ifndef STRING_HASH_COMPOSE_TEST_HPP
#define STRING_HASH_COMPOSE_TEST_HPP

#include "../TestSuite.hpp"

void registerStringHashComposeTests(Testing::TestSuite& suite);

#endif // STRING_HASH_COMPOSE_TEST_HPP
