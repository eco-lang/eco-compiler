/**
 * Unit tests for AllocatorCommon.hpp functions.
 *
 * These tests verify the correctness of utility functions used across
 * the allocator subsystem, particularly getObjectSize() which is critical
 * for correct heap traversal during GC.
 */

#include "AllocatorCommonTest.hpp"
#include <cstring>
#include <rapidcheck.h>
#include "AllocatorCommon.hpp"
#include "Heap.hpp"

using namespace Elm;

// ============================================================================
// Helper: Create objects in stack-allocated buffer
// ============================================================================

// Aligned buffer for creating test objects on the stack.
// Large enough for any heap object type with some variable-length data.
alignas(8) static char test_buffer[1024];

// Helper to get a clean test object pointer.
static void* getTestObject() {
    std::memset(test_buffer, 0, sizeof(test_buffer));
    return static_cast<void*>(test_buffer);
}

// ============================================================================
// Fixed-Size Object Tests
// ============================================================================

Testing::TestCase testGetObjectSizeInt("getObjectSize returns correct size for ElmInt", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Int;

        size_t expected = (sizeof(ElmInt) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        RC_ASSERT(getObjectSize(obj) == 16);  // Header(8) + i64(8) = 16
    });
});

Testing::TestCase testGetObjectSizeFloat("getObjectSize returns correct size for ElmFloat", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Float;

        size_t expected = (sizeof(ElmFloat) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        RC_ASSERT(getObjectSize(obj) == 16);  // Header(8) + f64(8) = 16
    });
});

Testing::TestCase testGetObjectSizeChar("getObjectSize returns correct size for ElmChar", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Char;

        size_t expected = (sizeof(ElmChar) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        RC_ASSERT(getObjectSize(obj) == 16);  // Header(8) + u16 + padding = 16
    });
});

Testing::TestCase testGetObjectSizeTuple2("getObjectSize returns correct size for Tuple2", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Tuple2;

        size_t expected = (sizeof(Tuple2) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        RC_ASSERT(getObjectSize(obj) == 24);  // Header(8) + 2*Unboxable(16) = 24
    });
});

Testing::TestCase testGetObjectSizeTuple3("getObjectSize returns correct size for Tuple3", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Tuple3;

        size_t expected = (sizeof(Tuple3) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        RC_ASSERT(getObjectSize(obj) == 32);  // Header(8) + 3*Unboxable(24) = 32
    });
});

Testing::TestCase testGetObjectSizeCons("getObjectSize returns correct size for Cons", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Cons;

        size_t expected = (sizeof(Cons) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        RC_ASSERT(getObjectSize(obj) == 24);  // Header(8) + Unboxable(8) + HPointer(8) = 24
    });
});

Testing::TestCase testGetObjectSizeProcess("getObjectSize returns correct size for Process", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Process;

        size_t expected = (sizeof(Process) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        // Header(8) + id/padding(8) + 3*HPointer(24) = 40
        RC_ASSERT(getObjectSize(obj) == 40);
    });
});

Testing::TestCase testGetObjectSizeTask("getObjectSize returns correct size for Task", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Task;

        size_t expected = (sizeof(Task) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        // Header(8) + ctor/id/padding(8) + 4*HPointer(32) = 48
        RC_ASSERT(getObjectSize(obj) == 48);
    });
});

Testing::TestCase testGetObjectSizeForward("getObjectSize returns correct size for Forward", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Forward;

        size_t expected = (sizeof(Forward) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        RC_ASSERT(getObjectSize(obj) == 8);  // Just the header
    });
});

// ============================================================================
// Variable-Size Object Tests (using hdr->size)
// ============================================================================

Testing::TestCase testGetObjectSizeString("getObjectSize returns correct size for ElmString with varying lengths", []() {
    rc::check([](u32 num_chars) {
        // Limit to reasonable size to avoid buffer overflow in test
        num_chars = num_chars % 100;

        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_String;
        hdr->size = num_chars;

        size_t base_size = sizeof(ElmString);  // Just the header
        size_t expected = (base_size + num_chars * sizeof(u16) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
    });
});

Testing::TestCase testGetObjectSizeStringEdgeCases("getObjectSize handles ElmString edge cases", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_String;

        // Zero characters (empty string - though normally uses constant)
        hdr->size = 0;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(ElmString) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 8);  // Just aligned header

        // One character
        hdr->size = 1;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(ElmString) + 1 * sizeof(u16) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 16);  // 8 + 2 rounded up to 16

        // Four characters (exactly fills to 16 bytes)
        hdr->size = 4;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(ElmString) + 4 * sizeof(u16) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 16);  // 8 + 8 = 16

        // Five characters (needs 24 bytes)
        hdr->size = 5;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(ElmString) + 5 * sizeof(u16) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 24);  // 8 + 10 = 18, rounded to 24
    });
});

Testing::TestCase testGetObjectSizeCustom("getObjectSize returns correct size for Custom with varying field counts", []() {
    rc::check([](u32 num_values) {
        // Limit to reasonable size
        num_values = num_values % 50;

        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Custom;
        hdr->size = num_values;

        size_t base_size = sizeof(Custom);  // Header + ctor/unboxed
        size_t expected = (base_size + num_values * sizeof(Unboxable) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
    });
});

Testing::TestCase testGetObjectSizeCustomEdgeCases("getObjectSize handles Custom edge cases", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Custom;

        // Zero values
        hdr->size = 0;
        size_t base = (sizeof(Custom) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == base);
        RC_ASSERT(getObjectSize(obj) == 16);  // Header(8) + ctor/unboxed(8) = 16

        // One value
        hdr->size = 1;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(Custom) + 1 * sizeof(Unboxable) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 24);  // 16 + 8 = 24

        // Two values
        hdr->size = 2;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(Custom) + 2 * sizeof(Unboxable) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 32);  // 16 + 16 = 32
    });
});

Testing::TestCase testGetObjectSizeRecord("getObjectSize returns correct size for Record with varying field counts", []() {
    rc::check([](u32 num_values) {
        // Limit to reasonable size
        num_values = num_values % 50;

        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Record;
        hdr->size = num_values;

        size_t base_size = sizeof(Record);  // Header + unboxed bitmap
        size_t expected = (base_size + num_values * sizeof(Unboxable) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
    });
});

Testing::TestCase testGetObjectSizeRecordEdgeCases("getObjectSize handles Record edge cases", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Record;

        // Zero values
        hdr->size = 0;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(Record) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 16);  // Header(8) + unboxed(8) = 16

        // One value
        hdr->size = 1;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(Record) + 1 * sizeof(Unboxable) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 24);

        // Three values
        hdr->size = 3;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(Record) + 3 * sizeof(Unboxable) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 40);  // 16 + 24 = 40
    });
});

Testing::TestCase testGetObjectSizeDynRecord("getObjectSize returns correct size for DynRecord with varying field counts", []() {
    rc::check([](u32 num_values) {
        // Limit to reasonable size
        num_values = num_values % 50;

        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_DynRecord;
        hdr->size = num_values;

        size_t base_size = sizeof(DynRecord);  // Header + unboxed + fieldgroup
        size_t expected = (base_size + num_values * sizeof(HPointer) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
    });
});

Testing::TestCase testGetObjectSizeDynRecordEdgeCases("getObjectSize handles DynRecord edge cases", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_DynRecord;

        // Zero values
        hdr->size = 0;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(DynRecord) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 24);  // Header(8) + unboxed(8) + fieldgroup(8) = 24

        // One value
        hdr->size = 1;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(DynRecord) + 1 * sizeof(HPointer) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 32);  // 24 + 8 = 32

        // Three values
        hdr->size = 3;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(DynRecord) + 3 * sizeof(HPointer) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 48);  // 24 + 24 = 48
    });
});

Testing::TestCase testGetObjectSizeFieldGroup("getObjectSize returns correct size for FieldGroup with varying field counts", []() {
    rc::check([](u32 num_fields) {
        // Limit to reasonable size
        num_fields = num_fields % 50;

        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_FieldGroup;
        hdr->size = num_fields;

        size_t base_size = sizeof(FieldGroup);  // Header + count
        size_t expected = (base_size + num_fields * sizeof(u32) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
    });
});

Testing::TestCase testGetObjectSizeFieldGroupEdgeCases("getObjectSize handles FieldGroup edge cases", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_FieldGroup;

        // Zero fields
        hdr->size = 0;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(FieldGroup) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 16);  // Header(8) + count(4) + padding = 16

        // One field
        hdr->size = 1;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(FieldGroup) + 1 * sizeof(u32) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 16);  // 12 + 4 = 16

        // Two fields
        hdr->size = 2;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(FieldGroup) + 2 * sizeof(u32) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 24);  // 12 + 8 = 20, rounded to 24

        // Four fields
        hdr->size = 4;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(FieldGroup) + 4 * sizeof(u32) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 32);  // 12 + 16 = 28, rounded to 32
    });
});

// ============================================================================
// Closure Tests (uses n_values field instead of hdr->size)
// ============================================================================

Testing::TestCase testGetObjectSizeClosure("getObjectSize returns correct size for Closure with varying value counts", []() {
    rc::check([](u32 num_values) {
        // Limit to 63 (max for 6-bit field)
        num_values = num_values % 64;

        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Closure;

        Closure* cl = static_cast<Closure*>(obj);
        cl->n_values = num_values;

        size_t base_size = sizeof(Closure);  // Header + n_values/max_values/unboxed + evaluator
        size_t expected = (base_size + num_values * sizeof(Unboxable) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
    });
});

Testing::TestCase testGetObjectSizeClosureEdgeCases("getObjectSize handles Closure edge cases", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = Tag_Closure;

        Closure* cl = static_cast<Closure*>(obj);

        // Zero captured values
        cl->n_values = 0;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(Closure) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 24);  // Header(8) + bitfields(8) + evaluator(8) = 24

        // One captured value
        cl->n_values = 1;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(Closure) + 1 * sizeof(Unboxable) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 32);  // 24 + 8 = 32

        // Maximum values (63)
        cl->n_values = 63;
        RC_ASSERT(getObjectSize(obj) == ((sizeof(Closure) + 63 * sizeof(Unboxable) + 7) & ~7));
        RC_ASSERT(getObjectSize(obj) == 528);  // 24 + 504 = 528
    });
});

// ============================================================================
// Alignment Tests
// ============================================================================

Testing::TestCase testGetObjectSizeAlwaysAligned("getObjectSize always returns 8-byte aligned size", []() {
    rc::check([](u32 tag_val, u32 size_val) {
        // Test all valid tags
        tag_val = tag_val % (Tag_Forward + 1);
        // Limit size to reasonable value
        size_val = size_val % 100;

        void* obj = getTestObject();
        Header* hdr = getHeader(obj);
        hdr->tag = tag_val;
        hdr->size = size_val;

        // For Closure, also set n_values
        if (tag_val == Tag_Closure) {
            Closure* cl = static_cast<Closure*>(obj);
            cl->n_values = size_val % 64;
        }

        size_t result = getObjectSize(obj);
        RC_ASSERT(result % 8 == 0);
        RC_ASSERT(result >= 8);  // At least header size
    });
});

// ============================================================================
// Default Case Test
// ============================================================================

Testing::TestCase testGetObjectSizeUnknownTag("getObjectSize returns header size for unknown tags", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);

        // Use a tag value beyond the defined range
        hdr->tag = 31;  // Max value for 5-bit field, beyond Tag_Forward=14

        size_t expected = (sizeof(Header) + 7) & ~7;
        RC_ASSERT(getObjectSize(obj) == expected);
        RC_ASSERT(getObjectSize(obj) == 8);
    });
});

// ============================================================================
// Comprehensive Size Verification Tests
// ============================================================================

Testing::TestCase testGetObjectSizeAllTagsExhaustive("getObjectSize handles all valid tags correctly", []() {
    rc::check([]() {
        void* obj = getTestObject();
        Header* hdr = getHeader(obj);

        // Test each tag type with fixed hdr->size = 5 (for variable types)
        struct TagTest {
            Tag tag;
            size_t expected_size;
            const char* name;
        };

        TagTest tests[] = {
            {Tag_Int,       16,  "Int"},
            {Tag_Float,     16,  "Float"},
            {Tag_Char,      16,  "Char"},
            {Tag_Tuple2,    24,  "Tuple2"},
            {Tag_Tuple3,    32,  "Tuple3"},
            {Tag_Cons,      24,  "Cons"},
            {Tag_Process,   40,  "Process"},
            {Tag_Task,      48,  "Task"},
            {Tag_Forward,   8,   "Forward"},
        };

        for (const auto& test : tests) {
            std::memset(obj, 0, sizeof(test_buffer));
            hdr->tag = test.tag;
            size_t actual = getObjectSize(obj);
            RC_ASSERT(actual == test.expected_size);
        }

        // Variable-size types with hdr->size = 5
        hdr->size = 5;

        // String: sizeof(ElmString) + 5 * sizeof(u16) = 8 + 10 = 18 -> 24
        hdr->tag = Tag_String;
        RC_ASSERT(getObjectSize(obj) == 24);

        // Custom: sizeof(Custom) + 5 * sizeof(Unboxable) = 16 + 40 = 56
        hdr->tag = Tag_Custom;
        RC_ASSERT(getObjectSize(obj) == 56);

        // Record: sizeof(Record) + 5 * sizeof(Unboxable) = 16 + 40 = 56
        hdr->tag = Tag_Record;
        RC_ASSERT(getObjectSize(obj) == 56);

        // DynRecord: sizeof(DynRecord) + 5 * sizeof(HPointer) = 24 + 40 = 64
        hdr->tag = Tag_DynRecord;
        RC_ASSERT(getObjectSize(obj) == 64);

        // FieldGroup: sizeof(FieldGroup) + 5 * sizeof(u32) = 12 + 20 = 32
        hdr->tag = Tag_FieldGroup;
        RC_ASSERT(getObjectSize(obj) == 32);

        // Closure: sizeof(Closure) + 5 * sizeof(Unboxable) = 24 + 40 = 64
        hdr->tag = Tag_Closure;
        Closure* cl = static_cast<Closure*>(obj);
        cl->n_values = 5;
        RC_ASSERT(getObjectSize(obj) == 64);
    });
});
