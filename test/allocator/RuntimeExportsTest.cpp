/**
 * Property-based tests for RuntimeExports.cpp.
 *
 * Tests the C-linkage runtime functions used by LLVM-generated code.
 */

#include "RuntimeExportsTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <rapidcheck.h>
#include <cmath>
#include <cstring>

using namespace Elm;

// Helper to convert HPointer (as uint64_t) to raw pointer for test verification.
// This uses the same logic as hpointerToPtr in RuntimeExports.cpp.
static void* hptrToRaw(uint64_t hptr) {
    if (hptr == 0) return nullptr;
    HPointer hp;
    std::memcpy(&hp, &hptr, sizeof(hp));
    if (hp.constant != 0) return nullptr;  // Embedded constant, not a heap object
    return Allocator::instance().resolve(hp);
}

// Helper to get an HPointer uint64_t value representing Nil (for tail of lists)
static uint64_t nilHPtr() {
    HPointer nil = alloc::listNil();
    uint64_t result;
    std::memcpy(&result, &nil, sizeof(result));
    return result;
}

// ============================================================================
// Allocation Function Tests
// ============================================================================

static void test_eco_alloc_int_stores_value() {
    rc::check("eco_alloc_int stores correct value", []() {
        initAllocator();
        i64 value = *rc::gen::arbitrary<i64>();

        uint64_t hptr = eco_alloc_int(value);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        ElmInt* elmInt = static_cast<ElmInt*>(obj);
        RC_ASSERT(elmInt->header.tag == Tag_Int);
        RC_ASSERT(elmInt->value == value);
    });
}

static void test_eco_alloc_float_stores_value() {
    rc::check("eco_alloc_float stores correct value", []() {
        initAllocator();
        // Generate finite floats to avoid NaN comparison issues
        double value = *rc::gen::map(rc::gen::arbitrary<int>(), [](int x) {
            return static_cast<double>(x) / 100.0;
        });

        uint64_t hptr = eco_alloc_float(value);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
        RC_ASSERT(elmFloat->header.tag == Tag_Float);
        RC_ASSERT(elmFloat->value == value);
    });
}

static void test_eco_alloc_char_stores_value() {
    rc::check("eco_alloc_char stores correct value", []() {
        initAllocator();
        // Generate valid Unicode code points (BMP range for u16)
        uint32_t value = *rc::gen::inRange<uint32_t>(0, 0xFFFF);

        uint64_t hptr = eco_alloc_char(value);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        ElmChar* elmChar = static_cast<ElmChar*>(obj);
        RC_ASSERT(elmChar->header.tag == Tag_Char);
        RC_ASSERT(elmChar->value == static_cast<u16>(value));
    });
}

static void test_eco_alloc_cons_correct_tag() {
    rc::check("eco_alloc_cons creates object with Tag_Cons", []() {
        initAllocator();

        // eco_alloc_cons takes (head, tail, head_unboxed) - use Nil for empty values
        uint64_t nil = nilHPtr();
        uint64_t hptr = eco_alloc_cons(nil, nil, 0);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        Header* header = static_cast<Header*>(obj);
        RC_ASSERT(header->tag == Tag_Cons);
    });
}

static void test_eco_alloc_tuple2_correct_tag() {
    rc::check("eco_alloc_tuple2 creates object with Tag_Tuple2", []() {
        initAllocator();

        // eco_alloc_tuple2 takes (a, b, unboxed_mask) - use 0 for null values
        uint64_t hptr = eco_alloc_tuple2(0, 0, 0);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        Header* header = static_cast<Header*>(obj);
        RC_ASSERT(header->tag == Tag_Tuple2);
    });
}

static void test_eco_alloc_tuple3_correct_tag() {
    rc::check("eco_alloc_tuple3 creates object with Tag_Tuple3", []() {
        initAllocator();

        // eco_alloc_tuple3 takes (a, b, c, unboxed_mask)
        uint64_t hptr = eco_alloc_tuple3(0, 0, 0, 0);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        Header* header = static_cast<Header*>(obj);
        RC_ASSERT(header->tag == Tag_Tuple3);
    });
}

static void test_eco_alloc_custom_fields() {
    rc::check("eco_alloc_custom allocates with correct ctor and fields", []() {
        initAllocator();
        uint32_t ctor_tag = *rc::gen::inRange<uint32_t>(0, 100);
        uint32_t field_count = *rc::gen::inRange<uint32_t>(0, 10);

        uint64_t hptr = eco_alloc_custom(ctor_tag, field_count, 0);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        Custom* custom = static_cast<Custom*>(obj);
        RC_ASSERT(custom->header.tag == Tag_Custom);
        RC_ASSERT(custom->ctor == ctor_tag);
        // header.size stores field_count for Custom objects
        RC_ASSERT(custom->header.size == field_count);
    });
}

static void test_eco_alloc_string_length() {
    rc::check("eco_alloc_string sets header.size to length", []() {
        initAllocator();
        uint32_t length = *rc::gen::inRange<uint32_t>(1, 1000);

        uint64_t hptr = eco_alloc_string(length);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        ElmString* str = static_cast<ElmString*>(obj);
        RC_ASSERT(str->header.tag == Tag_String);
        RC_ASSERT(str->header.size == length);
    });
}

static void test_eco_alloc_closure_metadata() {
    rc::check("eco_alloc_closure sets metadata correctly", []() {
        initAllocator();
        uint32_t num_captures = *rc::gen::inRange<uint32_t>(0, 10);

        // Use a dummy function pointer
        void* func_ptr = reinterpret_cast<void*>(0x12345678);

        uint64_t hptr = eco_alloc_closure(func_ptr, num_captures);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        RC_ASSERT(static_cast<bool>(obj));

        Closure* closure = static_cast<Closure*>(obj);
        RC_ASSERT(closure->header.tag == Tag_Closure);
        RC_ASSERT(closure->n_values == 0);  // Initially no captured values
        RC_ASSERT(closure->max_values == num_captures);
        RC_ASSERT(closure->evaluator == reinterpret_cast<EvalFunction>(func_ptr));
    });
}

static void test_eco_allocate_generic() {
    rc::check("eco_allocate works with various tags", []() {
        initAllocator();

        // Test with Tag_Int
        uint64_t intHptr = eco_allocate(sizeof(ElmInt), Tag_Int);
        RC_ASSERT(intHptr != 0);
        void* intObj = hptrToRaw(intHptr);
        RC_ASSERT(static_cast<bool>(intObj));
        RC_ASSERT(static_cast<Header*>(intObj)->tag == Tag_Int);

        // Test with Tag_Float
        uint64_t floatHptr = eco_allocate(sizeof(ElmFloat), Tag_Float);
        RC_ASSERT(floatHptr != 0);
        void* floatObj = hptrToRaw(floatHptr);
        RC_ASSERT(static_cast<bool>(floatObj));
        RC_ASSERT(static_cast<Header*>(floatObj)->tag == Tag_Float);

        // Test with Tag_Cons
        uint64_t consHptr = eco_allocate(sizeof(Cons), Tag_Cons);
        RC_ASSERT(consHptr != 0);
        void* consObj = hptrToRaw(consHptr);
        RC_ASSERT(static_cast<bool>(consObj));
        RC_ASSERT(static_cast<Header*>(consObj)->tag == Tag_Cons);
    });
}

// ============================================================================
// Field Store Function Tests
// ============================================================================

static void test_eco_store_field_custom() {
    rc::check("eco_store_field stores values in Custom object fields", []() {
        initAllocator();
        uint32_t field_count = *rc::gen::inRange<uint32_t>(1, 5);
        uint32_t index = *rc::gen::inRange<uint32_t>(0, field_count);
        uint64_t value = *rc::gen::arbitrary<uint64_t>();

        uint64_t hptr = eco_alloc_custom(0, field_count, 0);
        RC_ASSERT(hptr != 0);

        eco_store_field(hptr, index, value);

        void* obj = hptrToRaw(hptr);
        Custom* custom = static_cast<Custom*>(obj);
        RC_ASSERT(static_cast<uint64_t>(custom->values[index].i) == value);
    });
}

static void test_eco_store_field_tuple2() {
    rc::check("eco_alloc_tuple2 initializes values correctly", []() {
        initAllocator();
        uint64_t val_a = *rc::gen::arbitrary<uint64_t>();
        uint64_t val_b = *rc::gen::arbitrary<uint64_t>();

        // eco_alloc_tuple2 now initializes fields directly with uint64_t values
        uint64_t hptr = eco_alloc_tuple2(val_a, val_b, 0);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        Tuple2* tuple = static_cast<Tuple2*>(obj);
        RC_ASSERT(static_cast<uint64_t>(tuple->a.i) == static_cast<i64>(val_a));
        RC_ASSERT(static_cast<uint64_t>(tuple->b.i) == static_cast<i64>(val_b));
    });
}

static void test_eco_store_field_tuple3() {
    rc::check("eco_alloc_tuple3 initializes values correctly", []() {
        initAllocator();
        uint64_t val_a = *rc::gen::arbitrary<uint64_t>();
        uint64_t val_b = *rc::gen::arbitrary<uint64_t>();
        uint64_t val_c = *rc::gen::arbitrary<uint64_t>();

        // eco_alloc_tuple3 now initializes fields directly with uint64_t values
        uint64_t hptr = eco_alloc_tuple3(val_a, val_b, val_c, 0);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        Tuple3* tuple = static_cast<Tuple3*>(obj);
        RC_ASSERT(static_cast<uint64_t>(tuple->a.i) == static_cast<i64>(val_a));
        RC_ASSERT(static_cast<uint64_t>(tuple->b.i) == static_cast<i64>(val_b));
        RC_ASSERT(static_cast<uint64_t>(tuple->c.i) == static_cast<i64>(val_c));
    });
}

static void test_eco_store_field_cons() {
    rc::check("eco_alloc_cons initializes head correctly", []() {
        initAllocator();
        uint64_t head_val = *rc::gen::arbitrary<uint64_t>();
        uint64_t nil = nilHPtr();

        // eco_alloc_cons now initializes head directly with uint64_t value
        uint64_t hptr = eco_alloc_cons(head_val, nil, 0);
        RC_ASSERT(hptr != 0);

        void* obj = hptrToRaw(hptr);
        Cons* cons = static_cast<Cons*>(obj);
        RC_ASSERT(static_cast<uint64_t>(cons->head.i) == static_cast<i64>(head_val));
    });
}

static void test_eco_store_field_closure() {
    rc::check("eco_store_field stores captured values in Closure", []() {
        initAllocator();
        uint32_t num_captures = *rc::gen::inRange<uint32_t>(1, 5);
        uint32_t index = *rc::gen::inRange<uint32_t>(0, num_captures);
        uint64_t value = *rc::gen::arbitrary<uint64_t>();

        uint64_t hptr = eco_alloc_closure(nullptr, num_captures);
        RC_ASSERT(hptr != 0);

        eco_store_field(hptr, index, value);

        void* obj = hptrToRaw(hptr);
        Closure* closure = static_cast<Closure*>(obj);
        RC_ASSERT(static_cast<uint64_t>(closure->values[index].i) == value);
    });
}

static void test_eco_store_field_i64() {
    rc::check("eco_store_field_i64 stores int64 values correctly", []() {
        initAllocator();
        i64 value = *rc::gen::arbitrary<i64>();

        uint64_t hptr = eco_alloc_custom(0, 1, 0);
        RC_ASSERT(hptr != 0);

        eco_store_field_i64(hptr, 0, value);

        void* obj = hptrToRaw(hptr);
        Custom* custom = static_cast<Custom*>(obj);
        RC_ASSERT(custom->values[0].i == value);
    });
}

static void test_eco_store_field_f64() {
    rc::check("eco_store_field_f64 stores double values correctly", []() {
        initAllocator();
        // Generate finite floats
        double value = *rc::gen::map(rc::gen::arbitrary<int>(), [](int x) {
            return static_cast<double>(x) / 100.0;
        });

        uint64_t hptr = eco_alloc_custom(0, 1, 0);
        RC_ASSERT(hptr != 0);

        eco_store_field_f64(hptr, 0, value);

        void* obj = hptrToRaw(hptr);
        Custom* custom = static_cast<Custom*>(obj);
        RC_ASSERT(custom->values[0].f == value);
    });
}

// ============================================================================
// Tag Extraction Tests
// ============================================================================

static void test_eco_get_header_tag() {
    rc::check("eco_get_header_tag returns correct tag", []() {
        initAllocator();
        uint64_t nil = nilHPtr();

        // Test various object types
        uint64_t intHptr = eco_alloc_int(42);
        RC_ASSERT(eco_get_header_tag(intHptr) == Tag_Int);

        uint64_t floatHptr = eco_alloc_float(3.14);
        RC_ASSERT(eco_get_header_tag(floatHptr) == Tag_Float);

        uint64_t charHptr = eco_alloc_char('A');
        RC_ASSERT(eco_get_header_tag(charHptr) == Tag_Char);

        uint64_t consHptr = eco_alloc_cons(nil, nil, 0);
        RC_ASSERT(eco_get_header_tag(consHptr) == Tag_Cons);

        uint64_t tuple2Hptr = eco_alloc_tuple2(0, 0, 0);
        RC_ASSERT(eco_get_header_tag(tuple2Hptr) == Tag_Tuple2);

        uint64_t tuple3Hptr = eco_alloc_tuple3(0, 0, 0, 0);
        RC_ASSERT(eco_get_header_tag(tuple3Hptr) == Tag_Tuple3);

        uint64_t customHptr = eco_alloc_custom(5, 2, 0);
        RC_ASSERT(eco_get_header_tag(customHptr) == Tag_Custom);

        uint64_t stringHptr = eco_alloc_string(10);
        RC_ASSERT(eco_get_header_tag(stringHptr) == Tag_String);

        uint64_t closureHptr = eco_alloc_closure(nullptr, 3);
        RC_ASSERT(eco_get_header_tag(closureHptr) == Tag_Closure);
    });
}

static void test_eco_get_custom_ctor() {
    rc::check("eco_get_custom_ctor returns correct constructor tag", []() {
        initAllocator();
        uint32_t ctor_tag = *rc::gen::inRange<uint32_t>(0, 1000);

        uint64_t hptr = eco_alloc_custom(ctor_tag, 0, 0);
        RC_ASSERT(hptr != 0);

        RC_ASSERT(eco_get_custom_ctor(hptr) == ctor_tag);
    });
}

// ============================================================================
// GC Integration Tests
// ============================================================================

static void test_allocated_objects_survive_minor_gc() {
    rc::check("objects allocated via eco_alloc_* survive minor GC when rooted", []() {
        auto& alloc = initAllocator();
        i64 value = *rc::gen::arbitrary<i64>();

        // Allocate an int - returns HPointer as uint64_t
        uint64_t hptr = eco_alloc_int(value);
        RC_ASSERT(hptr != 0);

        // Convert to HPointer struct for rooting
        HPointer ptr;
        std::memcpy(&ptr, &hptr, sizeof(ptr));

        // Register as root
        alloc.getRootSet().addRoot(&ptr);

        // Trigger minor GC
        alloc.minorGC();

        // Resolve and verify value preserved
        void* resolved = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(resolved));

        ElmInt* elmInt = static_cast<ElmInt*>(resolved);
        RC_ASSERT(elmInt->value == value);

        alloc.getRootSet().removeRoot(&ptr);
    });
}

static void test_allocated_objects_survive_major_gc() {
    rc::check("objects survive major GC when rooted", []() {
        auto& alloc = initAllocator();
        i64 value = *rc::gen::arbitrary<i64>();

        // Allocate an int
        uint64_t hptr = eco_alloc_int(value);
        RC_ASSERT(hptr != 0);

        HPointer ptr;
        std::memcpy(&ptr, &hptr, sizeof(ptr));
        alloc.getRootSet().addRoot(&ptr);

        // Promote to old gen
        promoteToOldGen(alloc);

        // Trigger major GC
        alloc.majorGC();

        // Verify value preserved
        void* resolved = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(resolved));

        ElmInt* elmInt = static_cast<ElmInt*>(resolved);
        RC_ASSERT(elmInt->value == value);

        alloc.getRootSet().removeRoot(&ptr);
    });
}

static void test_field_values_preserved_after_gc() {
    rc::check("field values stored via eco_store_field preserved after GC", []() {
        auto& alloc = initAllocator();

        // Create a tuple2 - allocators now initialize fields directly
        uint64_t tupleHptr = eco_alloc_tuple2(0, 0, 0);
        RC_ASSERT(tupleHptr != 0);

        // Allocate two integers
        i64 val1 = *rc::gen::inRange<i64>(-1000, 1000);
        i64 val2 = *rc::gen::inRange<i64>(-1000, 1000);

        uint64_t int1Hptr = eco_alloc_int(val1);
        uint64_t int2Hptr = eco_alloc_int(val2);
        RC_ASSERT(int1Hptr != 0);
        RC_ASSERT(int2Hptr != 0);

        // Store the integer HPointers in the tuple fields
        eco_store_field(tupleHptr, 0, int1Hptr);
        eco_store_field(tupleHptr, 1, int2Hptr);

        // Convert to HPointer structs and root
        HPointer tuplePtr, int1Ptr, int2Ptr;
        std::memcpy(&tuplePtr, &tupleHptr, sizeof(tuplePtr));
        std::memcpy(&int1Ptr, &int1Hptr, sizeof(int1Ptr));
        std::memcpy(&int2Ptr, &int2Hptr, sizeof(int2Ptr));

        alloc.getRootSet().addRoot(&tuplePtr);
        alloc.getRootSet().addRoot(&int1Ptr);
        alloc.getRootSet().addRoot(&int2Ptr);

        // Trigger GC
        alloc.minorGC();

        // Resolve and verify
        void* resolvedTuple = alloc.resolve(tuplePtr);
        RC_ASSERT(static_cast<bool>(resolvedTuple));

        void* resolvedInt1 = alloc.resolve(int1Ptr);
        void* resolvedInt2 = alloc.resolve(int2Ptr);
        RC_ASSERT(static_cast<bool>(resolvedInt1));
        RC_ASSERT(static_cast<bool>(resolvedInt2));

        ElmInt* elmInt1 = static_cast<ElmInt*>(resolvedInt1);
        ElmInt* elmInt2 = static_cast<ElmInt*>(resolvedInt2);
        RC_ASSERT(elmInt1->value == val1);
        RC_ASSERT(elmInt2->value == val2);

        alloc.getRootSet().removeRoot(&tuplePtr);
        alloc.getRootSet().removeRoot(&int1Ptr);
        alloc.getRootSet().removeRoot(&int2Ptr);
    });
}

static void test_multiple_alloc_types_survive_gc() {
    rc::check("multiple object types allocated via eco_alloc_* survive GC", []() {
        auto& alloc = initAllocator();
        uint64_t nil = nilHPtr();

        // Allocate various types - now returns HPointer as uint64_t
        uint64_t intHptr = eco_alloc_int(42);
        uint64_t floatHptr = eco_alloc_float(3.14159);
        uint64_t charHptr = eco_alloc_char('X');
        uint64_t consHptr = eco_alloc_cons(nil, nil, 0);
        uint64_t customHptr = eco_alloc_custom(7, 2, 0);

        RC_ASSERT(intHptr != 0);
        RC_ASSERT(floatHptr != 0);
        RC_ASSERT(charHptr != 0);
        RC_ASSERT(consHptr != 0);
        RC_ASSERT(customHptr != 0);

        // Convert to HPointer structs and root them
        HPointer intPtr, floatPtr, charPtr, consPtr, customPtr;
        std::memcpy(&intPtr, &intHptr, sizeof(intPtr));
        std::memcpy(&floatPtr, &floatHptr, sizeof(floatPtr));
        std::memcpy(&charPtr, &charHptr, sizeof(charPtr));
        std::memcpy(&consPtr, &consHptr, sizeof(consPtr));
        std::memcpy(&customPtr, &customHptr, sizeof(customPtr));

        alloc.getRootSet().addRoot(&intPtr);
        alloc.getRootSet().addRoot(&floatPtr);
        alloc.getRootSet().addRoot(&charPtr);
        alloc.getRootSet().addRoot(&consPtr);
        alloc.getRootSet().addRoot(&customPtr);

        // Trigger GC
        alloc.minorGC();

        // Convert back to uint64_t for tag checking
        uint64_t intHptrNew, floatHptrNew, charHptrNew, consHptrNew, customHptrNew;
        std::memcpy(&intHptrNew, &intPtr, sizeof(intHptrNew));
        std::memcpy(&floatHptrNew, &floatPtr, sizeof(floatHptrNew));
        std::memcpy(&charHptrNew, &charPtr, sizeof(charHptrNew));
        std::memcpy(&consHptrNew, &consPtr, sizeof(consHptrNew));
        std::memcpy(&customHptrNew, &customPtr, sizeof(customHptrNew));

        // Verify all tags preserved
        RC_ASSERT(eco_get_header_tag(intHptrNew) == Tag_Int);
        RC_ASSERT(eco_get_header_tag(floatHptrNew) == Tag_Float);
        RC_ASSERT(eco_get_header_tag(charHptrNew) == Tag_Char);
        RC_ASSERT(eco_get_header_tag(consHptrNew) == Tag_Cons);
        RC_ASSERT(eco_get_header_tag(customHptrNew) == Tag_Custom);

        // Verify custom ctor
        RC_ASSERT(eco_get_custom_ctor(customHptrNew) == 7);

        // Verify values
        RC_ASSERT(static_cast<ElmInt*>(alloc.resolve(intPtr))->value == 42);
        RC_ASSERT(static_cast<ElmFloat*>(alloc.resolve(floatPtr))->value == 3.14159);
        RC_ASSERT(static_cast<ElmChar*>(alloc.resolve(charPtr))->value == 'X');

        alloc.getRootSet().removeRoot(&intPtr);
        alloc.getRootSet().removeRoot(&floatPtr);
        alloc.getRootSet().removeRoot(&charPtr);
        alloc.getRootSet().removeRoot(&consPtr);
        alloc.getRootSet().removeRoot(&customPtr);
    });
}

// ============================================================================
// Test Registration
// ============================================================================

void registerRuntimeExportsTests(Testing::TestSuite& suite) {
    // Allocation function tests
    suite.add(Testing::TestCase("eco_alloc_int stores correct value", test_eco_alloc_int_stores_value));
    suite.add(Testing::TestCase("eco_alloc_float stores correct value", test_eco_alloc_float_stores_value));
    suite.add(Testing::TestCase("eco_alloc_char stores correct value", test_eco_alloc_char_stores_value));
    suite.add(Testing::TestCase("eco_alloc_cons creates Tag_Cons", test_eco_alloc_cons_correct_tag));
    suite.add(Testing::TestCase("eco_alloc_tuple2 creates Tag_Tuple2", test_eco_alloc_tuple2_correct_tag));
    suite.add(Testing::TestCase("eco_alloc_tuple3 creates Tag_Tuple3", test_eco_alloc_tuple3_correct_tag));
    suite.add(Testing::TestCase("eco_alloc_custom sets ctor and fields", test_eco_alloc_custom_fields));
    suite.add(Testing::TestCase("eco_alloc_string sets header.size", test_eco_alloc_string_length));
    suite.add(Testing::TestCase("eco_alloc_closure sets metadata", test_eco_alloc_closure_metadata));
    suite.add(Testing::TestCase("eco_allocate generic allocation", test_eco_allocate_generic));

    // Field store function tests
    suite.add(Testing::TestCase("eco_store_field Custom fields", test_eco_store_field_custom));
    suite.add(Testing::TestCase("eco_store_field Tuple2 fields", test_eco_store_field_tuple2));
    suite.add(Testing::TestCase("eco_store_field Tuple3 fields", test_eco_store_field_tuple3));
    suite.add(Testing::TestCase("eco_store_field Cons head", test_eco_store_field_cons));
    suite.add(Testing::TestCase("eco_store_field Closure captures", test_eco_store_field_closure));
    suite.add(Testing::TestCase("eco_store_field_i64 stores int64", test_eco_store_field_i64));
    suite.add(Testing::TestCase("eco_store_field_f64 stores double", test_eco_store_field_f64));

    // Tag extraction tests
    suite.add(Testing::TestCase("eco_get_header_tag returns correct tag", test_eco_get_header_tag));
    suite.add(Testing::TestCase("eco_get_custom_ctor returns ctor", test_eco_get_custom_ctor));

    // GC integration tests
    suite.add(Testing::TestCase("RuntimeExports: objects survive minor GC", test_allocated_objects_survive_minor_gc));
    suite.add(Testing::TestCase("RuntimeExports: objects survive major GC", test_allocated_objects_survive_major_gc));
    suite.add(Testing::TestCase("RuntimeExports: field values preserved after GC", test_field_values_preserved_after_gc));
    suite.add(Testing::TestCase("RuntimeExports: multiple types survive GC", test_multiple_alloc_types_survive_gc));
}
