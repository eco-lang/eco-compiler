/**
 * Property-based tests for RuntimeExports.cpp.
 *
 * Tests the C-linkage runtime functions used by LLVM-generated code.
 */

#include "RuntimeExportsTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <rapidcheck.h>
#include <cmath>

using namespace Elm;

// ============================================================================
// Allocation Function Tests
// ============================================================================

static void test_eco_alloc_int_stores_value() {
    rc::check("eco_alloc_int stores correct value", []() {
        initAllocator();
        i64 value = *rc::gen::arbitrary<i64>();

        void* obj = eco_alloc_int(value);
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

        void* obj = eco_alloc_float(value);
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

        void* obj = eco_alloc_char(value);
        RC_ASSERT(static_cast<bool>(obj));

        ElmChar* elmChar = static_cast<ElmChar*>(obj);
        RC_ASSERT(elmChar->header.tag == Tag_Char);
        RC_ASSERT(elmChar->value == static_cast<u16>(value));
    });
}

static void test_eco_alloc_cons_correct_tag() {
    rc::check("eco_alloc_cons creates object with Tag_Cons", []() {
        initAllocator();

        void* obj = eco_alloc_cons();
        RC_ASSERT(static_cast<bool>(obj));

        Header* header = static_cast<Header*>(obj);
        RC_ASSERT(header->tag == Tag_Cons);
    });
}

static void test_eco_alloc_tuple2_correct_tag() {
    rc::check("eco_alloc_tuple2 creates object with Tag_Tuple2", []() {
        initAllocator();

        void* obj = eco_alloc_tuple2();
        RC_ASSERT(static_cast<bool>(obj));

        Header* header = static_cast<Header*>(obj);
        RC_ASSERT(header->tag == Tag_Tuple2);
    });
}

static void test_eco_alloc_tuple3_correct_tag() {
    rc::check("eco_alloc_tuple3 creates object with Tag_Tuple3", []() {
        initAllocator();

        void* obj = eco_alloc_tuple3();
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

        void* obj = eco_alloc_custom(ctor_tag, field_count, 0);
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

        void* obj = eco_alloc_string(length);
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

        void* obj = eco_alloc_closure(func_ptr, num_captures);
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
        void* intObj = eco_allocate(sizeof(ElmInt), Tag_Int);
        RC_ASSERT(static_cast<bool>(intObj));
        RC_ASSERT(static_cast<Header*>(intObj)->tag == Tag_Int);

        // Test with Tag_Float
        void* floatObj = eco_allocate(sizeof(ElmFloat), Tag_Float);
        RC_ASSERT(static_cast<bool>(floatObj));
        RC_ASSERT(static_cast<Header*>(floatObj)->tag == Tag_Float);

        // Test with Tag_Cons
        void* consObj = eco_allocate(sizeof(Cons), Tag_Cons);
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

        void* obj = eco_alloc_custom(0, field_count, 0);
        RC_ASSERT(static_cast<bool>(obj));

        eco_store_field(obj, index, value);

        Custom* custom = static_cast<Custom*>(obj);
        RC_ASSERT(static_cast<uint64_t>(custom->values[index].i) == value);
    });
}

static void test_eco_store_field_tuple2() {
    rc::check("eco_store_field stores values in Tuple2 fields", []() {
        initAllocator();
        uint64_t val_a = *rc::gen::arbitrary<uint64_t>();
        uint64_t val_b = *rc::gen::arbitrary<uint64_t>();

        void* obj = eco_alloc_tuple2();
        RC_ASSERT(static_cast<bool>(obj));

        eco_store_field(obj, 0, val_a);
        eco_store_field(obj, 1, val_b);

        Tuple2* tuple = static_cast<Tuple2*>(obj);
        RC_ASSERT(static_cast<uint64_t>(tuple->a.i) == val_a);
        RC_ASSERT(static_cast<uint64_t>(tuple->b.i) == val_b);
    });
}

static void test_eco_store_field_tuple3() {
    rc::check("eco_store_field stores values in Tuple3 fields", []() {
        initAllocator();
        uint64_t val_a = *rc::gen::arbitrary<uint64_t>();
        uint64_t val_b = *rc::gen::arbitrary<uint64_t>();
        uint64_t val_c = *rc::gen::arbitrary<uint64_t>();

        void* obj = eco_alloc_tuple3();
        RC_ASSERT(static_cast<bool>(obj));

        eco_store_field(obj, 0, val_a);
        eco_store_field(obj, 1, val_b);
        eco_store_field(obj, 2, val_c);

        Tuple3* tuple = static_cast<Tuple3*>(obj);
        RC_ASSERT(static_cast<uint64_t>(tuple->a.i) == val_a);
        RC_ASSERT(static_cast<uint64_t>(tuple->b.i) == val_b);
        RC_ASSERT(static_cast<uint64_t>(tuple->c.i) == val_c);
    });
}

static void test_eco_store_field_cons() {
    rc::check("eco_store_field stores head in Cons cells", []() {
        initAllocator();
        uint64_t head_val = *rc::gen::arbitrary<uint64_t>();

        void* obj = eco_alloc_cons();
        RC_ASSERT(static_cast<bool>(obj));

        eco_store_field(obj, 0, head_val);

        Cons* cons = static_cast<Cons*>(obj);
        RC_ASSERT(static_cast<uint64_t>(cons->head.i) == head_val);
    });
}

static void test_eco_store_field_closure() {
    rc::check("eco_store_field stores captured values in Closure", []() {
        initAllocator();
        uint32_t num_captures = *rc::gen::inRange<uint32_t>(1, 5);
        uint32_t index = *rc::gen::inRange<uint32_t>(0, num_captures);
        uint64_t value = *rc::gen::arbitrary<uint64_t>();

        void* obj = eco_alloc_closure(nullptr, num_captures);
        RC_ASSERT(static_cast<bool>(obj));

        eco_store_field(obj, index, value);

        Closure* closure = static_cast<Closure*>(obj);
        RC_ASSERT(static_cast<uint64_t>(closure->values[index].i) == value);
    });
}

static void test_eco_store_field_i64() {
    rc::check("eco_store_field_i64 stores int64 values correctly", []() {
        initAllocator();
        i64 value = *rc::gen::arbitrary<i64>();

        void* obj = eco_alloc_custom(0, 1, 0);
        RC_ASSERT(static_cast<bool>(obj));

        eco_store_field_i64(obj, 0, value);

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

        void* obj = eco_alloc_custom(0, 1, 0);
        RC_ASSERT(static_cast<bool>(obj));

        eco_store_field_f64(obj, 0, value);

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

        // Test various object types
        void* intObj = eco_alloc_int(42);
        RC_ASSERT(eco_get_header_tag(intObj) == Tag_Int);

        void* floatObj = eco_alloc_float(3.14);
        RC_ASSERT(eco_get_header_tag(floatObj) == Tag_Float);

        void* charObj = eco_alloc_char('A');
        RC_ASSERT(eco_get_header_tag(charObj) == Tag_Char);

        void* consObj = eco_alloc_cons();
        RC_ASSERT(eco_get_header_tag(consObj) == Tag_Cons);

        void* tuple2Obj = eco_alloc_tuple2();
        RC_ASSERT(eco_get_header_tag(tuple2Obj) == Tag_Tuple2);

        void* tuple3Obj = eco_alloc_tuple3();
        RC_ASSERT(eco_get_header_tag(tuple3Obj) == Tag_Tuple3);

        void* customObj = eco_alloc_custom(5, 2, 0);
        RC_ASSERT(eco_get_header_tag(customObj) == Tag_Custom);

        void* stringObj = eco_alloc_string(10);
        RC_ASSERT(eco_get_header_tag(stringObj) == Tag_String);

        void* closureObj = eco_alloc_closure(nullptr, 3);
        RC_ASSERT(eco_get_header_tag(closureObj) == Tag_Closure);
    });
}

static void test_eco_get_custom_ctor() {
    rc::check("eco_get_custom_ctor returns correct constructor tag", []() {
        initAllocator();
        uint32_t ctor_tag = *rc::gen::inRange<uint32_t>(0, 1000);

        void* obj = eco_alloc_custom(ctor_tag, 0, 0);
        RC_ASSERT(static_cast<bool>(obj));

        RC_ASSERT(eco_get_custom_ctor(obj) == ctor_tag);
    });
}

// ============================================================================
// GC Integration Tests
// ============================================================================

static void test_allocated_objects_survive_minor_gc() {
    rc::check("objects allocated via eco_alloc_* survive minor GC when rooted", []() {
        auto& alloc = initAllocator();
        i64 value = *rc::gen::arbitrary<i64>();

        // Allocate an int
        void* obj = eco_alloc_int(value);
        RC_ASSERT(static_cast<bool>(obj));

        // Create an HPointer from the raw pointer for rooting
        // In non-JIT mode, we'd convert to logical pointer, but for testing
        // we work with the allocator's pointer system
        HPointer ptr = alloc.wrap(obj);

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
        void* obj = eco_alloc_int(value);
        RC_ASSERT(static_cast<bool>(obj));

        HPointer ptr = alloc.wrap(obj);
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

        // Create a tuple2 and store integer values in its fields
        void* tupleObj = eco_alloc_tuple2();
        RC_ASSERT(static_cast<bool>(tupleObj));

        // Allocate two integers
        i64 val1 = *rc::gen::inRange<i64>(-1000, 1000);
        i64 val2 = *rc::gen::inRange<i64>(-1000, 1000);

        void* int1 = eco_alloc_int(val1);
        void* int2 = eco_alloc_int(val2);
        RC_ASSERT(static_cast<bool>(int1));
        RC_ASSERT(static_cast<bool>(int2));

        // Store the integer pointers in the tuple fields
        eco_store_field(tupleObj, 0, reinterpret_cast<uint64_t>(int1));
        eco_store_field(tupleObj, 1, reinterpret_cast<uint64_t>(int2));

        // Root the tuple
        HPointer tuplePtr = alloc.wrap(tupleObj);
        alloc.getRootSet().addRoot(&tuplePtr);

        // Also root the integers (they need to survive)
        HPointer int1Ptr = alloc.wrap(int1);
        HPointer int2Ptr = alloc.wrap(int2);
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

        // Allocate various types
        void* intObj = eco_alloc_int(42);
        void* floatObj = eco_alloc_float(3.14159);
        void* charObj = eco_alloc_char('X');
        void* consObj = eco_alloc_cons();
        void* customObj = eco_alloc_custom(7, 2, 0);

        RC_ASSERT(static_cast<bool>(intObj));
        RC_ASSERT(static_cast<bool>(floatObj));
        RC_ASSERT(static_cast<bool>(charObj));
        RC_ASSERT(static_cast<bool>(consObj));
        RC_ASSERT(static_cast<bool>(customObj));

        // Create HPointers and root them
        HPointer intPtr = alloc.wrap(intObj);
        HPointer floatPtr = alloc.wrap(floatObj);
        HPointer charPtr = alloc.wrap(charObj);
        HPointer consPtr = alloc.wrap(consObj);
        HPointer customPtr = alloc.wrap(customObj);

        alloc.getRootSet().addRoot(&intPtr);
        alloc.getRootSet().addRoot(&floatPtr);
        alloc.getRootSet().addRoot(&charPtr);
        alloc.getRootSet().addRoot(&consPtr);
        alloc.getRootSet().addRoot(&customPtr);

        // Trigger GC
        alloc.minorGC();

        // Verify all tags preserved
        RC_ASSERT(eco_get_header_tag(alloc.resolve(intPtr)) == Tag_Int);
        RC_ASSERT(eco_get_header_tag(alloc.resolve(floatPtr)) == Tag_Float);
        RC_ASSERT(eco_get_header_tag(alloc.resolve(charPtr)) == Tag_Char);
        RC_ASSERT(eco_get_header_tag(alloc.resolve(consPtr)) == Tag_Cons);
        RC_ASSERT(eco_get_header_tag(alloc.resolve(customPtr)) == Tag_Custom);

        // Verify custom ctor
        RC_ASSERT(eco_get_custom_ctor(alloc.resolve(customPtr)) == 7);

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
