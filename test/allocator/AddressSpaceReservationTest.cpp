/**
 * Tests for reserveAddressSpaceBelow (PlatformVirtualMemory.hpp).
 *
 * The new HPointer representation stores raw absolute heap addresses in the low
 * 43 bits of a 64-bit word, so the entire heap must be reserved below 2^43.
 * These tests verify the platform primitive that guarantees that placement, and
 * that the configured allocator heap actually lands under the limit.
 */

#include "AddressSpaceReservationTest.hpp"

#include <cstdint>
#include <cstring>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "PlatformVirtualMemory.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

namespace {

// A modest reservation used for the placement/commit tests. Address space only —
// physical memory is committed lazily and released immediately.
constexpr std::size_t kTestReserve = 64ULL * 1024 * 1024;  // 64 MiB
constexpr std::uintptr_t kLimit = HPOINTER_ADDRESS_LIMIT;   // 2^43

}  // namespace

Testing::TestCase testReserveBelowFitsUnderLimit(
    "reserveAddressSpaceBelow places the whole region below 2^43", []() {
        void* base = platform::reserveAddressSpaceBelow(kTestReserve, kLimit);
        TEST_ASSERT(base != nullptr);
        auto b = reinterpret_cast<std::uintptr_t>(base);
        TEST_ASSERT(b + kTestReserve <= kLimit);
        // 8-byte aligned so the low 3 bits are free for the HPointer metadata.
        TEST_ASSERT((b & 0x7ULL) == 0);
        TEST_ASSERT(platform::releaseReservation(base, kTestReserve));
    });

Testing::TestCase testReserveBelowCommitRoundTrip(
    "reserveAddressSpaceBelow region can be committed, written, and decommitted",
    []() {
        void* base = platform::reserveAddressSpaceBelow(kTestReserve, kLimit);
        TEST_ASSERT(base != nullptr);

        // Commit the first page and round-trip a value through it.
        constexpr std::size_t kPage = 4096;
        void* committed = platform::commitAt(base, kPage);
        TEST_ASSERT(committed == base);
        auto* cell = static_cast<volatile std::uint64_t*>(base);
        *cell = 0xABCDEF0123456789ULL;
        TEST_ASSERT(*cell == 0xABCDEF0123456789ULL);

        TEST_ASSERT(platform::decommit(base, kPage));
        TEST_ASSERT(platform::releaseReservation(base, kTestReserve));
    });

Testing::TestCase testReserveBelowRejectsOversize(
    "reserveAddressSpaceBelow returns nullptr when size exceeds the limit", []() {
        // A reservation larger than the whole address budget cannot fit.
        void* base = platform::reserveAddressSpaceBelow(kLimit + kTestReserve, kLimit);
        TEST_ASSERT(base == nullptr);
        // A zero-size request is likewise rejected.
        TEST_ASSERT(platform::reserveAddressSpaceBelow(0, kLimit) == nullptr);
    });

// Note: the guarantee that the *configured* allocator heap fits below the limit
// is enforced at runtime inside Allocator::initialize() (it throws if
// reserveAddressSpaceBelow cannot place the reservation), which every E2E and
// allocator test exercises. A dedicated singleton-state check here would be
// order-fragile under seed-randomized test runs, so it is intentionally omitted.
