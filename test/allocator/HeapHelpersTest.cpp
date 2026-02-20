/**
 * Property-based tests for HeapHelpers.hpp.
 *
 * Tests allocation utilities for creating Elm values on the GC-managed heap.
 */

#include "HeapHelpersTest.hpp"
#include <rapidcheck.h>
#include <cstring>
#include <cmath>
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "TestHelpers.hpp"

using namespace Elm;
using namespace Elm::alloc;

// ============================================================================
// Embedded Constants Tests
// ============================================================================

Testing::UnitTest testNilConstant("Nil constant has correct field", []() {
    HPointer nil = listNil();
    TEST_ASSERT(nil.constant == Const_Nil + 1);
    TEST_ASSERT(nil.ptr == 0);
    TEST_ASSERT(isNil(nil));
    TEST_ASSERT(isConstant(nil));
});

Testing::UnitTest testUnitConstant("Unit constant has correct field", []() {
    HPointer u = unit();
    TEST_ASSERT(u.constant == Const_Unit + 1);
    TEST_ASSERT(isConstant(u));
    TEST_ASSERT(!isNil(u));
});

Testing::UnitTest testBoolConstants("Bool constants are distinct", []() {
    HPointer t = elmTrue();
    HPointer f = elmFalse();
    TEST_ASSERT(t.constant == Const_True + 1);
    TEST_ASSERT(f.constant == Const_False + 1);
    TEST_ASSERT(t.constant != f.constant);
    TEST_ASSERT(isConstant(t));
    TEST_ASSERT(isConstant(f));
});

Testing::UnitTest testNothingConstant("Nothing constant has correct field", []() {
    HPointer n = nothing();
    TEST_ASSERT(n.constant == Const_Nothing + 1);
    TEST_ASSERT(isConstant(n));
});

Testing::UnitTest testEmptyStringConstant("Empty string constant has correct field", []() {
    HPointer e = emptyString();
    TEST_ASSERT(e.constant == Const_EmptyString + 1);
    TEST_ASSERT(isConstant(e));
});

Testing::UnitTest testEmptyRecordConstant("Empty record constant has correct field", []() {
    HPointer r = emptyRecord();
    TEST_ASSERT(r.constant == Const_EmptyRec + 1);
    TEST_ASSERT(isConstant(r));
});

Testing::UnitTest testAllConstantsDistinct("All constants are distinguishable", []() {
    HPointer constants[] = {
        listNil(), unit(), elmTrue(), elmFalse(),
        nothing(), emptyString(), emptyRecord()
    };

    for (size_t i = 0; i < 7; ++i) {
        for (size_t j = i + 1; j < 7; ++j) {
            TEST_ASSERT(constants[i].constant != constants[j].constant);
        }
    }
});

// ============================================================================
// Primitive Allocation Tests
// ============================================================================

Testing::TestCase testAllocIntPreservesValue("allocInt preserves value", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 value = *rc::gen::arbitrary<i64>();
        HPointer ptr = allocInt(value);

        RC_ASSERT(!isConstant(ptr));

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));

        ElmInt* intObj = static_cast<ElmInt*>(obj);
        RC_ASSERT(intObj->header.tag == Tag_Int);
        RC_ASSERT(intObj->value == value);
    });
});

Testing::TestCase testAllocFloatPreservesValue("allocFloat preserves value", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Generate finite floats only
        f64 value = *rc::gen::suchThat(rc::gen::arbitrary<f64>(), [](f64 f) {
            return std::isfinite(f);
        });

        HPointer ptr = allocFloat(value);

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));

        ElmFloat* floatObj = static_cast<ElmFloat*>(obj);
        RC_ASSERT(floatObj->header.tag == Tag_Float);
        RC_ASSERT(floatObj->value == value);
    });
});

Testing::TestCase testAllocCharPreservesValue("allocChar preserves value", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        u16 value = *rc::gen::arbitrary<u16>();
        HPointer ptr = allocChar(value);

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));

        ElmChar* charObj = static_cast<ElmChar*>(obj);
        RC_ASSERT(charObj->header.tag == Tag_Char);
        RC_ASSERT(charObj->value == value);
    });
});

// ============================================================================
// Unboxable Helper Tests
// ============================================================================

Testing::TestCase testUnboxedIntValue("unboxedInt creates correct Unboxable", []() {
    rc::check([]() {
        i64 value = *rc::gen::arbitrary<i64>();
        Unboxable u = unboxedInt(value);
        RC_ASSERT(u.i == value);
    });
});

Testing::TestCase testUnboxedFloatValue("unboxedFloat creates correct Unboxable", []() {
    rc::check([]() {
        f64 value = *rc::gen::suchThat(rc::gen::arbitrary<f64>(), [](f64 f) {
            return std::isfinite(f);
        });
        Unboxable u = unboxedFloat(value);
        RC_ASSERT(u.f == value);
    });
});

Testing::TestCase testUnboxedCharValue("unboxedChar creates correct Unboxable", []() {
    rc::check([]() {
        u16 value = *rc::gen::arbitrary<u16>();
        Unboxable u = unboxedChar(value);
        RC_ASSERT(u.c == value);
    });
});

// ============================================================================
// String Allocation Tests
// ============================================================================

Testing::UnitTest testEmptyStringReturnsConstant("Empty string returns constant", []() {
    initAllocator();

    HPointer ptr = allocString(u"");
    TEST_ASSERT(isConstant(ptr));
    TEST_ASSERT(ptr.constant == Const_EmptyString + 1);
});

Testing::TestCase testStringLengthPreserved("String length preserved", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 100);
        std::u16string str;
        str.reserve(len);
        for (size_t i = 0; i < len; ++i) {
            str.push_back(static_cast<char16_t>(*rc::gen::inRange<int>(32, 126)));
        }

        HPointer ptr = allocString(str);
        RC_ASSERT(!isConstant(ptr));

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(stringLength(obj) == len);
    });
});

Testing::TestCase testStringDataPreserved("String data preserved", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 50);
        std::u16string str;
        for (size_t i = 0; i < len; ++i) {
            str.push_back(static_cast<char16_t>(*rc::gen::inRange<int>(32, 126)));
        }

        HPointer ptr = allocString(str);
        void* obj = alloc.resolve(ptr);

        const u16* data = stringData(obj);
        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(data[i] == static_cast<u16>(str[i]));
        }
    });
});

Testing::TestCase testAllocStringFromUTF8("UTF-8 string allocation works", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Generate ASCII string for simplicity
        size_t len = *rc::gen::inRange<size_t>(1, 50);
        std::string ascii;
        for (size_t i = 0; i < len; ++i) {
            ascii.push_back(static_cast<char>(*rc::gen::inRange<int>(32, 126)));
        }

        HPointer ptr = allocStringFromUTF8(ascii);
        void* obj = alloc.resolve(ptr);

        RC_ASSERT(stringLength(obj) == len);

        const u16* data = stringData(obj);
        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(data[i] == static_cast<u16>(ascii[i]));
        }
    });
});

// ============================================================================
// List Allocation Tests
// ============================================================================

Testing::UnitTest testConsCreatesValidCell("cons creates valid Cons cell", []() {
    auto& alloc = initAllocator();

    HPointer ptr = cons(unboxedInt(42), listNil(), false);

    TEST_ASSERT(!isConstant(ptr));

    void* obj = alloc.resolve(ptr);
    TEST_ASSERT(obj != nullptr);

    Header* hdr = static_cast<Header*>(obj);
    TEST_ASSERT(hdr->tag == Tag_Cons);
});

Testing::TestCase testConsPreservesHeadAndTail("cons preserves head and tail", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 value = *rc::gen::arbitrary<i64>();
        HPointer ptr = cons(unboxedInt(value), listNil(), false);

        void* obj = alloc.resolve(ptr);
        Cons* cell = static_cast<Cons*>(obj);

        RC_ASSERT(cell->head.i == value);
        RC_ASSERT(isNil(cell->tail));
        RC_ASSERT(cell->header.unboxed & 1);  // Head is unboxed
    });
});

Testing::TestCase testListFromIntsRoundtrip("listFromInts roundtrip", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(0, 20);
        std::vector<i64> values;
        for (size_t i = 0; i < len; ++i) {
            values.push_back(*rc::gen::inRange<i64>(-1000, 1000));
        }

        HPointer list = listFromInts(values);

        // Extract values back
        std::vector<i64> extracted;
        HPointer current = list;
        while (!isNil(current)) {
            void* obj = alloc.resolve(current);
            RC_ASSERT(static_cast<bool>(obj));

            Cons* cell = static_cast<Cons*>(obj);
            extracted.push_back(cell->head.i);
            current = cell->tail;
        }

        RC_ASSERT(extracted == values);
    });
});

Testing::TestCase testUnboxedFlagSetCorrectly("Unboxed flag set correctly for cons", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 value = *rc::gen::arbitrary<i64>();

        // Unboxed head
        HPointer unboxedPtr = cons(unboxedInt(value), listNil(), false);
        void* unboxedObj = alloc.resolve(unboxedPtr);
        Cons* unboxedCell = static_cast<Cons*>(unboxedObj);
        RC_ASSERT((unboxedCell->header.unboxed & 1) == 1);

        // Boxed head
        HPointer boxedInt = allocInt(value);
        HPointer boxedPtr = cons(boxed(boxedInt), listNil(), true);
        void* boxedObj = alloc.resolve(boxedPtr);
        Cons* boxedCell = static_cast<Cons*>(boxedObj);
        RC_ASSERT((boxedCell->header.unboxed & 1) == 0);
    });
});

// ============================================================================
// Tuple Allocation Tests
// ============================================================================

Testing::TestCase testTuple2PreservesValues("tuple2 preserves values", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 a = *rc::gen::arbitrary<i64>();
        i64 b = *rc::gen::arbitrary<i64>();

        HPointer ptr = tuple2(unboxedInt(a), unboxedInt(b), 0x3);

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));

        Tuple2* tuple = static_cast<Tuple2*>(obj);
        RC_ASSERT(tuple->header.tag == Tag_Tuple2);
        RC_ASSERT(tuple->a.i == a);
        RC_ASSERT(tuple->b.i == b);
        RC_ASSERT(tuple->header.unboxed == 3);
    });
});

Testing::TestCase testTuple3PreservesValues("tuple3 preserves values", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 a = *rc::gen::arbitrary<i64>();
        i64 b = *rc::gen::arbitrary<i64>();
        i64 c = *rc::gen::arbitrary<i64>();

        HPointer ptr = tuple3(unboxedInt(a), unboxedInt(b), unboxedInt(c), 0x7);

        void* obj = alloc.resolve(ptr);
        Tuple3* tuple = static_cast<Tuple3*>(obj);

        RC_ASSERT(tuple->header.tag == Tag_Tuple3);
        RC_ASSERT(tuple->a.i == a);
        RC_ASSERT(tuple->b.i == b);
        RC_ASSERT(tuple->c.i == c);
        RC_ASSERT(tuple->header.unboxed == 7);
    });
});

// ============================================================================
// Array Allocation Tests
// ============================================================================

Testing::TestCase testAllocArrayCapacity("allocArray creates correct capacity", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t capacity = *rc::gen::inRange<size_t>(1, 64);
        HPointer ptr = allocArray(capacity);

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(arrayCapacity(obj) == capacity);
        RC_ASSERT(arrayLength(obj) == 0);
    });
});

Testing::TestCase testArrayPushIncrementsLength("arrayPush increments length", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t capacity = *rc::gen::inRange<size_t>(5, 20);
        size_t pushCount = *rc::gen::inRange<size_t>(1, capacity);

        HPointer ptr = allocArray(capacity);
        void* obj = alloc.resolve(ptr);

        for (size_t i = 0; i < pushCount; ++i) {
            bool success = arrayPush(obj, unboxedInt(static_cast<i64>(i)), false);
            RC_ASSERT(success);
        }

        RC_ASSERT(arrayLength(obj) == pushCount);
    });
});

Testing::TestCase testArrayPushRespectsCapacity("arrayPush respects capacity", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t capacity = *rc::gen::inRange<size_t>(1, 10);
        HPointer ptr = allocArray(capacity);
        void* obj = alloc.resolve(ptr);

        // Fill to capacity
        for (size_t i = 0; i < capacity; ++i) {
            RC_ASSERT(arrayPush(obj, unboxedInt(static_cast<i64>(i)), false));
        }

        // Next push should fail
        RC_ASSERT(!arrayPush(obj, unboxedInt(999), false));
        RC_ASSERT(arrayLength(obj) == capacity);
    });
});

Testing::TestCase testArrayFromIntsRoundtrip("arrayFromInts roundtrip", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 30);
        std::vector<i64> values;
        for (size_t i = 0; i < len; ++i) {
            values.push_back(*rc::gen::inRange<i64>(-1000, 1000));
        }

        HPointer ptr = arrayFromInts(values);
        void* obj = alloc.resolve(ptr);

        RC_ASSERT(arrayLength(obj) == len);
        RC_ASSERT(arrayIsUnboxed(obj));  // Arrays are uniform - check once

        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(arrayGet(obj, i).i == values[i]);
        }
    });
});

// ============================================================================
// ByteBuffer Allocation Tests
// ============================================================================

Testing::TestCase testAllocByteBufferPreservesData("allocByteBuffer preserves data", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 100);
        std::vector<u8> data;
        for (size_t i = 0; i < len; ++i) {
            data.push_back(*rc::gen::arbitrary<u8>());
        }

        HPointer ptr = allocByteBuffer(data.data(), data.size());
        void* obj = alloc.resolve(ptr);

        RC_ASSERT(byteBufferLength(obj) == len);

        const u8* bufData = byteBufferData(obj);
        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(bufData[i] == data[i]);
        }
    });
});

Testing::TestCase testAllocByteBufferZeroIsZeroed("allocByteBufferZero is zeroed", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 100);
        HPointer ptr = allocByteBufferZero(len);
        void* obj = alloc.resolve(ptr);

        RC_ASSERT(byteBufferLength(obj) == len);

        const u8* data = byteBufferData(obj);
        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(data[i] == 0);
        }
    });
});

// ============================================================================
// Custom Type Allocation Tests
// ============================================================================

Testing::TestCase testJustPreservesValue("just preserves value", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 value = *rc::gen::arbitrary<i64>();
        HPointer ptr = just(unboxedInt(value), false);

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));

        Custom* custom = static_cast<Custom*>(obj);
        RC_ASSERT(custom->header.tag == Tag_Custom);
        RC_ASSERT(custom->header.size == 1);
        RC_ASSERT(custom->values[0].i == value);
    });
});

// ============================================================================
// Type Checking Tests
// ============================================================================

Testing::UnitTest testGetTagReturnsCorrectTag("getTag returns correct tag", []() {
    auto& alloc = initAllocator();

    HPointer intPtr = allocInt(42);
    void* intObj = alloc.resolve(intPtr);
    TEST_ASSERT(getTag(intObj) == Tag_Int);

    HPointer strPtr = allocString(u"hello");
    void* strObj = alloc.resolve(strPtr);
    TEST_ASSERT(getTag(strObj) == Tag_String);
    TEST_ASSERT(isString(strObj));

    HPointer consPtr = cons(unboxedInt(1), listNil(), false);
    void* consObj = alloc.resolve(consPtr);
    TEST_ASSERT(getTag(consObj) == Tag_Cons);
    TEST_ASSERT(isCons(consObj));
});

// ============================================================================
// GC Survival Tests
// ============================================================================

Testing::TestCase testAllocatedStringSurvivesMinorGC("Allocated string survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 50);
        std::u16string str;
        for (size_t i = 0; i < len; ++i) {
            str.push_back(static_cast<char16_t>(*rc::gen::inRange<int>(65, 90)));
        }

        HPointer ptr = allocString(str);

        // Register as root
        alloc.getRootSet().addRoot(&ptr);

        // Trigger GC
        alloc.minorGC();

        // Verify via possibly-updated ptr
        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(stringLength(obj) == len);

        const u16* data = stringData(obj);
        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(data[i] == static_cast<u16>(str[i]));
        }

        alloc.getRootSet().removeRoot(&ptr);
    });
});

Testing::TestCase testAllocatedListSurvivesMinorGC("Allocated list survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 20);
        std::vector<i64> values;
        for (size_t i = 0; i < len; ++i) {
            values.push_back(*rc::gen::inRange<i64>(-100, 100));
        }

        HPointer list = listFromInts(values);
        alloc.getRootSet().addRoot(&list);

        alloc.minorGC();

        // Verify list
        std::vector<i64> extracted;
        HPointer current = list;
        while (!isNil(current)) {
            void* obj = alloc.resolve(current);
            RC_ASSERT(static_cast<bool>(obj));
            Cons* cell = static_cast<Cons*>(obj);
            extracted.push_back(cell->head.i);
            current = cell->tail;
        }

        RC_ASSERT(extracted == values);

        alloc.getRootSet().removeRoot(&list);
    });
});

Testing::TestCase testAllocatedArraySurvivesMinorGC("Allocated array survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 30);
        std::vector<i64> values;
        for (size_t i = 0; i < len; ++i) {
            values.push_back(*rc::gen::inRange<i64>(-100, 100));
        }

        HPointer ptr = arrayFromInts(values);
        alloc.getRootSet().addRoot(&ptr);

        alloc.minorGC();

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(arrayLength(obj) == len);

        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(arrayGet(obj, i).i == values[i]);
        }

        alloc.getRootSet().removeRoot(&ptr);
    });
});

Testing::TestCase testAllocatedByteBufferSurvivesMinorGC("Allocated ByteBuffer survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 100);
        std::vector<u8> data;
        for (size_t i = 0; i < len; ++i) {
            data.push_back(*rc::gen::arbitrary<u8>());
        }

        HPointer ptr = allocByteBuffer(data.data(), data.size());
        alloc.getRootSet().addRoot(&ptr);

        alloc.minorGC();

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(byteBufferLength(obj) == len);

        const u8* bufData = byteBufferData(obj);
        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(bufData[i] == data[i]);
        }

        alloc.getRootSet().removeRoot(&ptr);
    });
});

Testing::TestCase testMixedStructuresSurviveGC("Mixed structures survive GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Create a string
        std::u16string str = u"test";
        HPointer strPtr = allocString(str);

        // Create a list
        std::vector<i64> listVals = {1, 2, 3};
        HPointer listPtr = listFromInts(listVals);

        // Create a tuple containing both
        HPointer tuple = tuple2(boxed(strPtr), boxed(listPtr), 0);

        alloc.getRootSet().addRoot(&tuple);

        // Trigger multiple GCs
        alloc.minorGC();
        alloc.minorGC();

        // Verify tuple and its contents
        void* tupleObj = alloc.resolve(tuple);
        RC_ASSERT(static_cast<bool>(tupleObj));

        Tuple2* t = static_cast<Tuple2*>(tupleObj);

        void* strObj = alloc.resolve(t->a.p);
        RC_ASSERT(static_cast<bool>(strObj));
        RC_ASSERT(stringLength(strObj) == 4);

        void* listObj = alloc.resolve(t->b.p);
        RC_ASSERT(static_cast<bool>(listObj));

        alloc.getRootSet().removeRoot(&tuple);
    });
});

// ============================================================================
// Test Registration
// ============================================================================

void registerHeapHelpersTests(Testing::TestSuite& suite) {
    // Embedded constants
    suite.add(testNilConstant);
    suite.add(testUnitConstant);
    suite.add(testBoolConstants);
    suite.add(testNothingConstant);
    suite.add(testEmptyStringConstant);
    suite.add(testEmptyRecordConstant);
    suite.add(testAllConstantsDistinct);

    // Primitive allocation
    suite.add(testAllocIntPreservesValue);
    suite.add(testAllocFloatPreservesValue);
    suite.add(testAllocCharPreservesValue);

    // Unboxable helpers
    suite.add(testUnboxedIntValue);
    suite.add(testUnboxedFloatValue);
    suite.add(testUnboxedCharValue);

    // String allocation
    suite.add(testEmptyStringReturnsConstant);
    suite.add(testStringLengthPreserved);
    suite.add(testStringDataPreserved);
    suite.add(testAllocStringFromUTF8);

    // List allocation
    suite.add(testConsCreatesValidCell);
    suite.add(testConsPreservesHeadAndTail);
    suite.add(testListFromIntsRoundtrip);
    suite.add(testUnboxedFlagSetCorrectly);

    // Tuple allocation
    suite.add(testTuple2PreservesValues);
    suite.add(testTuple3PreservesValues);

    // Array allocation
    suite.add(testAllocArrayCapacity);
    suite.add(testArrayPushIncrementsLength);
    suite.add(testArrayPushRespectsCapacity);
    suite.add(testArrayFromIntsRoundtrip);

    // ByteBuffer allocation
    suite.add(testAllocByteBufferPreservesData);
    suite.add(testAllocByteBufferZeroIsZeroed);

    // Custom types
    suite.add(testJustPreservesValue);

    // Type checking
    suite.add(testGetTagReturnsCorrectTag);

    // GC survival
    suite.add(testAllocatedStringSurvivesMinorGC);
    suite.add(testAllocatedListSurvivesMinorGC);
    suite.add(testAllocatedArraySurvivesMinorGC);
    suite.add(testAllocatedByteBufferSurvivesMinorGC);
    suite.add(testMixedStructuresSurviveGC);
}
