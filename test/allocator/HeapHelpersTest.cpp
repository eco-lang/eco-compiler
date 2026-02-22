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

Testing::TestCase testCreateBoxedArrayRoundtrip("createBoxedArray roundtrip", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(1, 20);
        std::vector<i64> values;
        std::vector<HPointer> ptrs;
        for (size_t i = 0; i < len; ++i) {
            i64 v = *rc::gen::inRange<i64>(-1000, 1000);
            values.push_back(v);
            ptrs.push_back(allocInt(v));
        }

        HPointer arr = arrayFromPointers(ptrs);
        void* obj = alloc.resolve(arr);

        RC_ASSERT(arrayLength(obj) == len);
        RC_ASSERT(!arrayIsUnboxed(obj));

        for (size_t i = 0; i < len; ++i) {
            HPointer elem = arrayGet(obj, i).p;
            void* elemObj = alloc.resolve(elem);
            ElmInt* intVal = static_cast<ElmInt*>(elemObj);
            RC_ASSERT(intVal->value == values[i]);
        }
    });
});

Testing::TestCase testBoxedArrayPush("boxedArrayPush keeps unboxed flag 0", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t capacity = *rc::gen::inRange<size_t>(3, 10);
        HPointer arr = allocArray(capacity);
        void* obj = alloc.resolve(arr);

        for (size_t i = 0; i < capacity; ++i) {
            HPointer val = allocInt(static_cast<i64>(i * 100));
            obj = alloc.resolve(arr);
            RC_ASSERT(arrayPush(obj, boxed(val), true));
        }

        obj = alloc.resolve(arr);
        RC_ASSERT(!arrayIsUnboxed(obj));
        RC_ASSERT(arrayLength(obj) == capacity);
    });
});

Testing::TestCase testArrayUnboxedFlagInHeader("array unboxed flag stored in header", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Boxed array
        std::vector<HPointer> ptrs = {allocInt(1), allocInt(2)};
        HPointer boxedArr = arrayFromPointers(ptrs);
        ElmArray* ba = static_cast<ElmArray*>(alloc.resolve(boxedArr));
        RC_ASSERT(ba->header.unboxed == 0);

        // Unboxed array
        std::vector<i64> ints = {10, 20, 30};
        HPointer unboxedArr = arrayFromInts(ints);
        ElmArray* ua = static_cast<ElmArray*>(alloc.resolve(unboxedArr));
        RC_ASSERT(ua->header.unboxed == 1);
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

Testing::TestCase testBoxedArraySurvivesMinorGC("Boxed array survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(2, 15);
        std::vector<i64> values;
        for (size_t i = 0; i < len; ++i) {
            values.push_back(*rc::gen::inRange<i64>(-500, 500));
        }

        // Create boxed array of ElmInt pointers
        std::vector<HPointer> ptrs;
        for (size_t i = 0; i < len; ++i) {
            ptrs.push_back(allocInt(values[i]));
        }
        HPointer arr = arrayFromPointers(ptrs);
        alloc.getRootSet().addRoot(&arr);

        alloc.minorGC();

        void* obj = alloc.resolve(arr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(arrayLength(obj) == len);
        RC_ASSERT(!arrayIsUnboxed(obj));

        for (size_t i = 0; i < len; ++i) {
            HPointer elem = arrayGet(obj, i).p;
            void* elemObj = alloc.resolve(elem);
            RC_ASSERT(static_cast<bool>(elemObj));
            ElmInt* intVal = static_cast<ElmInt*>(elemObj);
            RC_ASSERT(intVal->value == values[i]);
        }

        alloc.getRootSet().removeRoot(&arr);
    });
});

Testing::TestCase testBoxedArrayElementsTracedByGC("Boxed array elements all traced by GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Create several ElmInts that are ONLY reachable through the array
        size_t len = *rc::gen::inRange<size_t>(3, 20);
        std::vector<i64> values;
        std::vector<HPointer> ptrs;
        for (size_t i = 0; i < len; ++i) {
            i64 v = static_cast<i64>(i * 1000 + 7);
            values.push_back(v);
            ptrs.push_back(allocInt(v));
        }
        HPointer arr = arrayFromPointers(ptrs);

        // Only root the array, not the individual ints
        alloc.getRootSet().addRoot(&arr);

        alloc.minorGC();

        // All elements (not just element 0) must survive
        void* obj = alloc.resolve(arr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(arrayLength(obj) == len);

        for (size_t i = 0; i < len; ++i) {
            HPointer elem = arrayGet(obj, i).p;
            void* elemObj = alloc.resolve(elem);
            RC_ASSERT(static_cast<bool>(elemObj));
            ElmInt* intVal = static_cast<ElmInt*>(elemObj);
            RC_ASSERT(intVal->value == values[i]);
        }

        alloc.getRootSet().removeRoot(&arr);
    });
});

Testing::TestCase testUnboxedArrayElementsNotTracedByGC("Unboxed array elements not traced as pointers", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Create unboxed array with arbitrary integer values
        size_t len = *rc::gen::inRange<size_t>(2, 30);
        std::vector<i64> values;
        for (size_t i = 0; i < len; ++i) {
            values.push_back(*rc::gen::inRange<i64>(-100000, 100000));
        }
        HPointer arr = arrayFromInts(values);
        alloc.getRootSet().addRoot(&arr);

        // GC should not crash trying to trace integers as pointers
        alloc.minorGC();

        void* obj = alloc.resolve(arr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(arrayIsUnboxed(obj));
        RC_ASSERT(arrayLength(obj) == len);

        for (size_t i = 0; i < len; ++i) {
            RC_ASSERT(arrayGet(obj, i).i == values[i]);
        }

        alloc.getRootSet().removeRoot(&arr);
    });
});

Testing::TestCase testArrayUnboxedFlagPreservedAcrossGC("Array unboxed flag preserved across GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Create one boxed and one unboxed array
        std::vector<HPointer> bPtrs = {allocInt(1), allocInt(2)};
        HPointer boxedArr = arrayFromPointers(bPtrs);

        std::vector<i64> uInts = {10, 20, 30};
        HPointer unboxedArr = arrayFromInts(uInts);

        alloc.getRootSet().addRoot(&boxedArr);
        alloc.getRootSet().addRoot(&unboxedArr);

        alloc.minorGC();

        ElmArray* ba = static_cast<ElmArray*>(alloc.resolve(boxedArr));
        RC_ASSERT(ba->header.unboxed == 0);

        ElmArray* ua = static_cast<ElmArray*>(alloc.resolve(unboxedArr));
        RC_ASSERT(ua->header.unboxed == 1);

        alloc.getRootSet().removeRoot(&boxedArr);
        alloc.getRootSet().removeRoot(&unboxedArr);
    });
});

Testing::TestCase testEmptyArraySurvivesGC("Empty array survives GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        HPointer arr = allocArray(0);
        alloc.getRootSet().addRoot(&arr);

        alloc.minorGC();

        void* obj = alloc.resolve(arr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(arrayLength(obj) == 0);

        alloc.getRootSet().removeRoot(&arr);
    });
});

Testing::TestCase testLargeBoxedArraySurvivesGC("Large boxed array (100+ elements) survives GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t len = *rc::gen::inRange<size_t>(100, 150);
        std::vector<i64> values;
        std::vector<HPointer> ptrs;
        for (size_t i = 0; i < len; ++i) {
            i64 v = static_cast<i64>(i);
            values.push_back(v);
            ptrs.push_back(allocInt(v));
        }
        HPointer arr = arrayFromPointers(ptrs);
        alloc.getRootSet().addRoot(&arr);

        alloc.minorGC();

        void* obj = alloc.resolve(arr);
        RC_ASSERT(static_cast<bool>(obj));
        RC_ASSERT(arrayLength(obj) == len);

        for (size_t i = 0; i < len; ++i) {
            HPointer elem = arrayGet(obj, i).p;
            void* elemObj = alloc.resolve(elem);
            RC_ASSERT(static_cast<bool>(elemObj));
            ElmInt* intVal = static_cast<ElmInt*>(elemObj);
            RC_ASSERT(intVal->value == values[i]);
        }

        alloc.getRootSet().removeRoot(&arr);
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
// Group A: ElmFloat GC Survival
// ============================================================================

Testing::TestCase testAllocatedFloatSurvivesMinorGC("Allocated float survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        f64 value = *rc::gen::suchThat<f64>([](f64 v) { return std::isfinite(v); });
        HPointer ptr = allocFloat(value);
        alloc.getRootSet().addRoot(&ptr);

        alloc.minorGC();

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));
        ElmFloat* f = static_cast<ElmFloat*>(obj);
        RC_ASSERT(f->header.tag == Tag_Float);
        RC_ASSERT(f->value == value);

        alloc.getRootSet().removeRoot(&ptr);
    });
});

// ============================================================================
// Group B: ElmChar GC Survival
// ============================================================================

Testing::TestCase testAllocatedCharSurvivesMinorGC("Allocated char survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        u16 value = *rc::gen::arbitrary<u16>();
        HPointer ptr = allocChar(value);
        alloc.getRootSet().addRoot(&ptr);

        alloc.minorGC();

        void* obj = alloc.resolve(ptr);
        RC_ASSERT(static_cast<bool>(obj));
        ElmChar* c = static_cast<ElmChar*>(obj);
        RC_ASSERT(c->header.tag == Tag_Char);
        RC_ASSERT(c->value == value);

        alloc.getRootSet().removeRoot(&ptr);
    });
});

// ============================================================================
// Group C: Tuple3 GC Survival and Tracing
// ============================================================================

Testing::TestCase testTuple3BoxedSurvivesMinorGC("Tuple3 boxed children survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 va = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vb = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vc = *rc::gen::inRange<i64>(-1000, 1000);

        HPointer ia = allocInt(va);
        HPointer ib = allocInt(vb);
        HPointer ic = allocInt(vc);

        // All boxed: unboxed_mask = 0
        HPointer t = tuple3(boxed(ia), boxed(ib), boxed(ic), 0);
        alloc.getRootSet().addRoot(&t);

        alloc.minorGC();

        Tuple3* tp = static_cast<Tuple3*>(alloc.resolve(t));
        RC_ASSERT(static_cast<bool>(tp));
        RC_ASSERT(tp->header.unboxed == 0);

        ElmInt* ra = static_cast<ElmInt*>(alloc.resolve(tp->a.p));
        ElmInt* rb = static_cast<ElmInt*>(alloc.resolve(tp->b.p));
        ElmInt* rc2 = static_cast<ElmInt*>(alloc.resolve(tp->c.p));
        RC_ASSERT(ra->value == va);
        RC_ASSERT(rb->value == vb);
        RC_ASSERT(rc2->value == vc);

        alloc.getRootSet().removeRoot(&t);
    });
});

Testing::TestCase testTuple3UnboxedSurvivesMinorGC("Tuple3 unboxed fields survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 va = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vb = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vc = *rc::gen::inRange<i64>(-1000, 1000);

        // All unboxed: unboxed_mask = 7
        HPointer t = tuple3(unboxedInt(va), unboxedInt(vb), unboxedInt(vc), 7);
        alloc.getRootSet().addRoot(&t);

        alloc.minorGC();

        Tuple3* tp = static_cast<Tuple3*>(alloc.resolve(t));
        RC_ASSERT(static_cast<bool>(tp));
        RC_ASSERT(tp->header.unboxed == 7);
        RC_ASSERT(tp->a.i == va);
        RC_ASSERT(tp->b.i == vb);
        RC_ASSERT(tp->c.i == vc);

        alloc.getRootSet().removeRoot(&t);
    });
});

Testing::TestCase testTuple3MixedSurvivesMinorGC("Tuple3 mixed boxed/unboxed survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 va = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vb = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vc = *rc::gen::inRange<i64>(-1000, 1000);

        HPointer ia = allocInt(va);
        // a=boxed, b=unboxed, c=unboxed -> mask = 0b110 = 6
        HPointer t = tuple3(boxed(ia), unboxedInt(vb), unboxedInt(vc), 6);
        alloc.getRootSet().addRoot(&t);

        alloc.minorGC();

        Tuple3* tp = static_cast<Tuple3*>(alloc.resolve(t));
        RC_ASSERT(static_cast<bool>(tp));
        RC_ASSERT(tp->header.unboxed == 6);

        ElmInt* ra = static_cast<ElmInt*>(alloc.resolve(tp->a.p));
        RC_ASSERT(ra->value == va);
        RC_ASSERT(tp->b.i == vb);
        RC_ASSERT(tp->c.i == vc);

        alloc.getRootSet().removeRoot(&t);
    });
});

// ============================================================================
// Group D: Custom GC Survival and Tracing
// ============================================================================

Testing::TestCase testCustomBoxedFieldsSurviveMinorGC("Custom boxed fields survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t n = *rc::gen::inRange<size_t>(2, 6);
        std::vector<i64> vals;
        std::vector<Unboxable> fields;
        for (size_t i = 0; i < n; ++i) {
            i64 v = *rc::gen::inRange<i64>(-1000, 1000);
            vals.push_back(v);
            fields.push_back(boxed(allocInt(v)));
        }

        HPointer c = custom(0, fields, 0);
        alloc.getRootSet().addRoot(&c);

        alloc.minorGC();

        Custom* cp = static_cast<Custom*>(alloc.resolve(c));
        RC_ASSERT(static_cast<bool>(cp));
        RC_ASSERT(cp->header.size == static_cast<u32>(n));
        RC_ASSERT(cp->unboxed == 0);

        for (size_t i = 0; i < n; ++i) {
            ElmInt* ei = static_cast<ElmInt*>(alloc.resolve(cp->values[i].p));
            RC_ASSERT(static_cast<bool>(ei));
            RC_ASSERT(ei->value == vals[i]);
        }

        alloc.getRootSet().removeRoot(&c);
    });
});

Testing::TestCase testCustomUnboxedFieldsSurviveMinorGC("Custom unboxed fields survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t n = *rc::gen::inRange<size_t>(1, 6);
        std::vector<i64> vals;
        std::vector<Unboxable> fields;
        u64 mask = 0;
        for (size_t i = 0; i < n; ++i) {
            i64 v = *rc::gen::inRange<i64>(-100000, 100000);
            vals.push_back(v);
            fields.push_back(unboxedInt(v));
            mask |= (1ULL << i);
        }

        HPointer c = custom(0, fields, mask);
        alloc.getRootSet().addRoot(&c);

        alloc.minorGC();

        Custom* cp = static_cast<Custom*>(alloc.resolve(c));
        RC_ASSERT(static_cast<bool>(cp));
        RC_ASSERT(cp->unboxed == mask);

        for (size_t i = 0; i < n; ++i) {
            RC_ASSERT(cp->values[i].i == vals[i]);
        }

        alloc.getRootSet().removeRoot(&c);
    });
});

Testing::TestCase testCustomMixedFieldsSurviveMinorGC("Custom mixed boxed/unboxed fields survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // 4 fields: 0,2 boxed; 1,3 unboxed -> mask = 0b1010 = 0xA
        i64 v0 = *rc::gen::inRange<i64>(-1000, 1000);
        i64 v1 = *rc::gen::inRange<i64>(-100000, 100000);
        i64 v2 = *rc::gen::inRange<i64>(-1000, 1000);
        i64 v3 = *rc::gen::inRange<i64>(-100000, 100000);

        std::vector<Unboxable> fields(4);
        fields[0] = boxed(allocInt(v0));
        fields[1] = unboxedInt(v1);
        fields[2] = boxed(allocInt(v2));
        fields[3] = unboxedInt(v3);

        HPointer c = custom(0, fields, 0xA);
        alloc.getRootSet().addRoot(&c);

        alloc.minorGC();

        Custom* cp = static_cast<Custom*>(alloc.resolve(c));
        RC_ASSERT(static_cast<bool>(cp));
        RC_ASSERT(cp->unboxed == 0xA);

        ElmInt* r0 = static_cast<ElmInt*>(alloc.resolve(cp->values[0].p));
        RC_ASSERT(r0->value == v0);
        RC_ASSERT(cp->values[1].i == v1);
        ElmInt* r2 = static_cast<ElmInt*>(alloc.resolve(cp->values[2].p));
        RC_ASSERT(r2->value == v2);
        RC_ASSERT(cp->values[3].i == v3);

        alloc.getRootSet().removeRoot(&c);
    });
});

// ============================================================================
// Group E: Record GC Survival and Tracing
// ============================================================================

Testing::TestCase testRecordBoxedFieldsSurviveMinorGC("Record boxed fields survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t n = *rc::gen::inRange<size_t>(1, 5);
        std::vector<i64> vals;
        std::vector<Unboxable> fields;
        for (size_t i = 0; i < n; ++i) {
            i64 v = *rc::gen::inRange<i64>(-1000, 1000);
            vals.push_back(v);
            fields.push_back(boxed(allocInt(v)));
        }

        HPointer r = record(fields, 0);
        alloc.getRootSet().addRoot(&r);

        alloc.minorGC();

        Record* rp = static_cast<Record*>(alloc.resolve(r));
        RC_ASSERT(static_cast<bool>(rp));
        RC_ASSERT(rp->header.size == static_cast<u32>(n));
        RC_ASSERT(rp->unboxed == 0);

        for (size_t i = 0; i < n; ++i) {
            ElmInt* ei = static_cast<ElmInt*>(alloc.resolve(rp->values[i].p));
            RC_ASSERT(static_cast<bool>(ei));
            RC_ASSERT(ei->value == vals[i]);
        }

        alloc.getRootSet().removeRoot(&r);
    });
});

Testing::TestCase testRecordMixedFieldsSurviveMinorGC("Record mixed boxed/unboxed fields survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // 4 fields: 0,2 boxed; 1,3 unboxed -> mask = 0xA
        i64 v0 = *rc::gen::inRange<i64>(-1000, 1000);
        i64 v1 = *rc::gen::inRange<i64>(-100000, 100000);
        i64 v2 = *rc::gen::inRange<i64>(-1000, 1000);
        i64 v3 = *rc::gen::inRange<i64>(-100000, 100000);

        std::vector<Unboxable> fields(4);
        fields[0] = boxed(allocInt(v0));
        fields[1] = unboxedInt(v1);
        fields[2] = boxed(allocInt(v2));
        fields[3] = unboxedInt(v3);

        HPointer r = record(fields, 0xA);
        alloc.getRootSet().addRoot(&r);

        alloc.minorGC();

        Record* rp = static_cast<Record*>(alloc.resolve(r));
        RC_ASSERT(static_cast<bool>(rp));
        RC_ASSERT(rp->unboxed == 0xA);

        ElmInt* r0 = static_cast<ElmInt*>(alloc.resolve(rp->values[0].p));
        RC_ASSERT(r0->value == v0);
        RC_ASSERT(rp->values[1].i == v1);
        ElmInt* r2 = static_cast<ElmInt*>(alloc.resolve(rp->values[2].p));
        RC_ASSERT(r2->value == v2);
        RC_ASSERT(rp->values[3].i == v3);

        alloc.getRootSet().removeRoot(&r);
    });
});

// ============================================================================
// Group F: Closure GC Survival and Tracing
// ============================================================================

Testing::TestCase testClosureBoxedCapturesSurviveMinorGC("Closure boxed captures survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        size_t n = *rc::gen::inRange<size_t>(1, 5);
        std::vector<i64> vals;

        HPointer cl = allocClosure(nullptr, static_cast<u32>(n));
        for (size_t i = 0; i < n; ++i) {
            i64 v = *rc::gen::inRange<i64>(-1000, 1000);
            vals.push_back(v);
            HPointer iv = allocInt(v);
            void* clObj = alloc.resolve(cl);
            closureCapture(clObj, boxed(iv), true);
        }

        alloc.getRootSet().addRoot(&cl);

        alloc.minorGC();

        Closure* cp = static_cast<Closure*>(alloc.resolve(cl));
        RC_ASSERT(static_cast<bool>(cp));
        RC_ASSERT(cp->n_values == static_cast<u32>(n));
        RC_ASSERT(cp->unboxed == 0);

        for (size_t i = 0; i < n; ++i) {
            ElmInt* ei = static_cast<ElmInt*>(alloc.resolve(cp->values[i].p));
            RC_ASSERT(static_cast<bool>(ei));
            RC_ASSERT(ei->value == vals[i]);
        }

        alloc.getRootSet().removeRoot(&cl);
    });
});

Testing::TestCase testClosureMixedCapturesSurviveMinorGC("Closure mixed captures survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // 3 captures: 0=boxed, 1=unboxed, 2=unboxed
        i64 v0 = *rc::gen::inRange<i64>(-1000, 1000);
        i64 v1 = *rc::gen::inRange<i64>(-100000, 100000);
        i64 v2 = *rc::gen::inRange<i64>(-100000, 100000);

        HPointer cl = allocClosure(nullptr, 3);
        HPointer iv0 = allocInt(v0);

        void* clObj = alloc.resolve(cl);
        closureCapture(clObj, boxed(iv0), true);
        closureCapture(clObj, unboxedInt(v1), false);
        closureCapture(clObj, unboxedInt(v2), false);

        alloc.getRootSet().addRoot(&cl);

        alloc.minorGC();

        Closure* cp = static_cast<Closure*>(alloc.resolve(cl));
        RC_ASSERT(static_cast<bool>(cp));
        RC_ASSERT(cp->n_values == 3);
        // Bits 1,2 set for unboxed captures
        RC_ASSERT((cp->unboxed & 0x6) == 0x6);
        RC_ASSERT((cp->unboxed & 0x1) == 0);

        ElmInt* r0 = static_cast<ElmInt*>(alloc.resolve(cp->values[0].p));
        RC_ASSERT(r0->value == v0);
        RC_ASSERT(cp->values[1].i == v1);
        RC_ASSERT(cp->values[2].i == v2);

        alloc.getRootSet().removeRoot(&cl);
    });
});

// ============================================================================
// Group G: Process GC Survival and Tracing
// ============================================================================

Testing::TestCase testProcessChildrenSurviveMinorGC("Process children survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 vr = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vs = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vm = *rc::gen::inRange<i64>(-1000, 1000);

        HPointer root = allocInt(vr);
        HPointer stack = allocInt(vs);
        HPointer mailbox = allocInt(vm);

        HPointer proc = allocProcess(42, root, stack, mailbox);
        alloc.getRootSet().addRoot(&proc);

        alloc.minorGC();

        Process* pp = static_cast<Process*>(alloc.resolve(proc));
        RC_ASSERT(static_cast<bool>(pp));
        RC_ASSERT(pp->header.tag == Tag_Process);
        RC_ASSERT(pp->id == 42);

        ElmInt* rr = static_cast<ElmInt*>(alloc.resolve(pp->root));
        ElmInt* rs = static_cast<ElmInt*>(alloc.resolve(pp->stack));
        ElmInt* rm = static_cast<ElmInt*>(alloc.resolve(pp->mailbox));
        RC_ASSERT(rr->value == vr);
        RC_ASSERT(rs->value == vs);
        RC_ASSERT(rm->value == vm);

        alloc.getRootSet().removeRoot(&proc);
    });
});

// ============================================================================
// Group H: Task GC Survival and Tracing
// ============================================================================

Testing::TestCase testTaskChildrenSurviveMinorGC("Task children survive minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        i64 vv = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vc = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vk = *rc::gen::inRange<i64>(-1000, 1000);
        i64 vt = *rc::gen::inRange<i64>(-1000, 1000);

        HPointer val = allocInt(vv);
        HPointer cb = allocInt(vc);
        HPointer kill = allocInt(vk);
        HPointer inner = allocInt(vt);

        HPointer task = allocTask(0, val, cb, kill, inner);
        alloc.getRootSet().addRoot(&task);

        alloc.minorGC();

        Task* tp = static_cast<Task*>(alloc.resolve(task));
        RC_ASSERT(static_cast<bool>(tp));
        RC_ASSERT(tp->header.tag == Tag_Task);

        ElmInt* rv = static_cast<ElmInt*>(alloc.resolve(tp->value));
        ElmInt* rcb = static_cast<ElmInt*>(alloc.resolve(tp->callback));
        ElmInt* rk = static_cast<ElmInt*>(alloc.resolve(tp->kill));
        ElmInt* rt = static_cast<ElmInt*>(alloc.resolve(tp->task));
        RC_ASSERT(rv->value == vv);
        RC_ASSERT(rcb->value == vc);
        RC_ASSERT(rk->value == vk);
        RC_ASSERT(rt->value == vt);

        alloc.getRootSet().removeRoot(&task);
    });
});

// ============================================================================
// Group I: DynRecord GC Survival and Tracing
// ============================================================================

Testing::TestCase testDynRecordSurvivesMinorGC("DynRecord with fieldgroup survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        // Allocate a FieldGroup with 2 field IDs
        size_t fg_size = sizeof(FieldGroup) + 2 * sizeof(u32);
        fg_size = (fg_size + 7) & ~7;
        FieldGroup* fg = static_cast<FieldGroup*>(alloc.allocate(fg_size, Tag_FieldGroup));
        fg->header.size = 0;
        fg->count = 2;
        fg->fields[0] = 100;
        fg->fields[1] = 200;
        HPointer fgPtr = alloc.wrap(fg);

        // Allocate 2 ElmInts as field values
        i64 v0 = *rc::gen::inRange<i64>(-1000, 1000);
        i64 v1 = *rc::gen::inRange<i64>(-1000, 1000);
        HPointer iv0 = allocInt(v0);
        HPointer iv1 = allocInt(v1);

        // Allocate DynRecord manually
        size_t dr_size = sizeof(DynRecord) + 2 * sizeof(HPointer);
        dr_size = (dr_size + 7) & ~7;
        DynRecord* dr = static_cast<DynRecord*>(alloc.allocate(dr_size, Tag_DynRecord));
        dr->header.size = 2;
        dr->unboxed = 0;
        dr->fieldgroup = fgPtr;
        dr->values[0] = iv0;
        dr->values[1] = iv1;
        HPointer drPtr = alloc.wrap(dr);

        alloc.getRootSet().addRoot(&drPtr);

        alloc.minorGC();

        DynRecord* drp = static_cast<DynRecord*>(alloc.resolve(drPtr));
        RC_ASSERT(static_cast<bool>(drp));
        RC_ASSERT(drp->header.tag == Tag_DynRecord);
        RC_ASSERT(drp->header.size == 2);

        // Verify fieldgroup survived
        FieldGroup* fgp = static_cast<FieldGroup*>(alloc.resolve(drp->fieldgroup));
        RC_ASSERT(static_cast<bool>(fgp));
        RC_ASSERT(fgp->count == 2);
        RC_ASSERT(fgp->fields[0] == 100);
        RC_ASSERT(fgp->fields[1] == 200);

        // Verify values survived
        ElmInt* r0 = static_cast<ElmInt*>(alloc.resolve(drp->values[0]));
        ElmInt* r1 = static_cast<ElmInt*>(alloc.resolve(drp->values[1]));
        RC_ASSERT(r0->value == v0);
        RC_ASSERT(r1->value == v1);

        alloc.getRootSet().removeRoot(&drPtr);
    });
});

// ============================================================================
// Group J: FieldGroup GC Survival
// ============================================================================

Testing::TestCase testFieldGroupSurvivesMinorGC("FieldGroup survives minor GC", []() {
    rc::check([]() {
        auto& alloc = initAllocator();

        u32 count = *rc::gen::inRange<u32>(1, 10);

        size_t fg_size = sizeof(FieldGroup) + count * sizeof(u32);
        fg_size = (fg_size + 7) & ~7;
        FieldGroup* fg = static_cast<FieldGroup*>(alloc.allocate(fg_size, Tag_FieldGroup));
        fg->header.size = 0;
        fg->count = count;
        std::vector<u32> fieldIds;
        for (u32 i = 0; i < count; ++i) {
            u32 fid = *rc::gen::inRange<u32>(0, 10000);
            fg->fields[i] = fid;
            fieldIds.push_back(fid);
        }
        HPointer fgPtr = alloc.wrap(fg);

        alloc.getRootSet().addRoot(&fgPtr);

        alloc.minorGC();

        FieldGroup* fgp = static_cast<FieldGroup*>(alloc.resolve(fgPtr));
        RC_ASSERT(static_cast<bool>(fgp));
        RC_ASSERT(fgp->header.tag == Tag_FieldGroup);
        RC_ASSERT(fgp->count == count);
        for (u32 i = 0; i < count; ++i) {
            RC_ASSERT(fgp->fields[i] == fieldIds[i]);
        }

        alloc.getRootSet().removeRoot(&fgPtr);
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
    suite.add(testCreateBoxedArrayRoundtrip);
    suite.add(testBoxedArrayPush);
    suite.add(testArrayUnboxedFlagInHeader);

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
    suite.add(testBoxedArraySurvivesMinorGC);
    suite.add(testBoxedArrayElementsTracedByGC);
    suite.add(testUnboxedArrayElementsNotTracedByGC);
    suite.add(testArrayUnboxedFlagPreservedAcrossGC);
    suite.add(testEmptyArraySurvivesGC);
    suite.add(testLargeBoxedArraySurvivesGC);
    suite.add(testAllocatedByteBufferSurvivesMinorGC);
    suite.add(testMixedStructuresSurviveGC);

    // Float / Char GC survival
    suite.add(testAllocatedFloatSurvivesMinorGC);
    suite.add(testAllocatedCharSurvivesMinorGC);

    // Tuple3 GC survival and tracing
    suite.add(testTuple3BoxedSurvivesMinorGC);
    suite.add(testTuple3UnboxedSurvivesMinorGC);
    suite.add(testTuple3MixedSurvivesMinorGC);

    // Custom GC survival and tracing
    suite.add(testCustomBoxedFieldsSurviveMinorGC);
    suite.add(testCustomUnboxedFieldsSurviveMinorGC);
    suite.add(testCustomMixedFieldsSurviveMinorGC);

    // Record GC survival and tracing
    suite.add(testRecordBoxedFieldsSurviveMinorGC);
    suite.add(testRecordMixedFieldsSurviveMinorGC);

    // Closure GC survival and tracing
    suite.add(testClosureBoxedCapturesSurviveMinorGC);
    suite.add(testClosureMixedCapturesSurviveMinorGC);

    // Process / Task GC survival and tracing
    suite.add(testProcessChildrenSurviveMinorGC);
    suite.add(testTaskChildrenSurviveMinorGC);

    // DynRecord / FieldGroup GC survival
    suite.add(testDynRecordSurvivesMinorGC);
    suite.add(testFieldGroupSurvivesMinorGC);
}
