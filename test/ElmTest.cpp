#include "ElmTest.hpp"
#include <cstring>
#include <rapidcheck.h>
#include "GarbageCollector.hpp"
#include "OldGenSpace.hpp"

namespace Elm {

// ============================================================================
// Elm List Runtime Functions
// ============================================================================

HPointer elm_nil() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Nil;
    ptr.padding = 0;
    return ptr;
}

HPointer elm_cons(HPointer head, HPointer tail) {
    auto& gc = GarbageCollector::instance();

    void* obj = gc.allocate(sizeof(Cons), Tag_Cons);
    if (!obj) {
        return elm_nil();  // Allocation failed.
    }

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = 0;  // Head is boxed (pointer).
    cons->head.p = head;
    cons->tail = tail;

    return toPointer(obj);
}

HPointer elm_cons_int(i64 value, HPointer tail) {
    auto& gc = GarbageCollector::instance();

    void* obj = gc.allocate(sizeof(Cons), Tag_Cons);
    if (!obj) {
        return elm_nil();  // Allocation failed.
    }

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = 1;  // Head is unboxed (integer).
    cons->head.i = value;
    cons->tail = tail;

    return toPointer(obj);
}

HPointer elm_reverse(HPointer list) {
    // Direct implementation: fold left, consing each element onto accumulator.
    // This avoids the complexity of generic foldl with function pointers.
    //
    // IMPORTANT: This function is GC-safe. We register local pointers as roots
    // so they get updated if GC triggers during allocation.
    auto& gc = GarbageCollector::instance();
    HPointer acc = elm_nil();

    // Register locals as roots so GC can update them if triggered.
    HPointer list_root = list;
    HPointer acc_root = acc;
    gc.getRootSet().addRoot(&list_root);
    gc.getRootSet().addRoot(&acc_root);

    while (list_root.constant != Const_Nil) {
        // Read current cons cell from root (root is always up-to-date).
        void* obj = fromPointer(list_root);
        if (!obj) break;

        Cons* cons = static_cast<Cons*>(obj);

        // Save unboxed flag and head VALUE (not pointer) before allocation.
        // For unboxed integers, head.i is just a value that doesn't need updating.
        u64 unboxed_flag = cons->header.unboxed;
        Unboxable head_copy = cons->head;

        // Advance list_root to next element BEFORE allocation.
        // Since list_root is a registered root, it will be updated if GC moves the object.
        list_root = cons->tail;

        // Create new cons cell - this might trigger GC!
        // After this, list_root may have been updated to point to new location.
        void* new_obj = gc.allocate(sizeof(Cons), Tag_Cons);
        if (!new_obj) break;

        Cons* new_cons = static_cast<Cons*>(new_obj);
        new_cons->header.unboxed = unboxed_flag;  // Preserve unboxed flag.
        new_cons->head = head_copy;  // Copy head value (integer or pointer).
        new_cons->tail = acc_root;   // Use root version which may have been updated.

        acc_root = toPointer(new_obj);
    }

    // Remove roots before returning.
    gc.getRootSet().removeRoot(&acc_root);
    gc.getRootSet().removeRoot(&list_root);

    return acc_root;
}

HPointer elm_foldl(HPointer (*func)(HPointer, HPointer), HPointer acc, HPointer list) {
    // Generic foldl - currently unused but kept for completeness.
    while (list.constant != Const_Nil) {
        void* obj = fromPointer(list);
        if (!obj) break;

        Cons* cons = static_cast<Cons*>(obj);

        // For generic foldl, we pass the head as-is.
        // The function must handle boxed/unboxed appropriately.
        HPointer head = cons->head.p;
        acc = func(head, acc);

        list = cons->tail;
    }
    return acc;
}

// ============================================================================
// Test Helpers
// ============================================================================

HPointer elm_list_from_ints(const std::vector<i64>& values) {
    HPointer list = elm_nil();

    // Build list in reverse order since cons prepends.
    for (auto it = values.rbegin(); it != values.rend(); ++it) {
        list = elm_cons_int(*it, list);
    }

    return list;
}

std::vector<i64> elm_list_to_ints(HPointer list) {
    std::vector<i64> result;

    while (list.constant != Const_Nil) {
        // Use readBarrier to handle forwarding pointers after GC.
        void* obj = readBarrier(list);
        if (!obj) break;

        Cons* cons = static_cast<Cons*>(obj);

        if (cons->header.unboxed & 1) {
            result.push_back(cons->head.i);
        } else {
            // Boxed value - try to extract if it's an ElmInt.
            HPointer head_ptr = cons->head.p;
            void* head_obj = readBarrier(head_ptr);
            if (head_obj) {
                Header* hdr = static_cast<Header*>(head_obj);
                if (hdr->tag == Tag_Int) {
                    ElmInt* elm_int = static_cast<ElmInt*>(head_obj);
                    result.push_back(elm_int->value);
                }
            }
        }

        list = cons->tail;
    }

    return result;
}

size_t elm_list_length(HPointer list) {
    size_t len = 0;

    while (list.constant != Const_Nil) {
        // Use readBarrier to handle forwarding pointers after GC.
        void* obj = readBarrier(list);
        if (!obj) break;

        Cons* cons = static_cast<Cons*>(obj);
        len++;
        list = cons->tail;
    }

    return len;
}

}  // namespace Elm

using namespace Elm;

// ============================================================================
// Tests
// ============================================================================

Testing::Test testElmNilConstant("Elm nil constant represents empty list", []() {
    rc::check("Nil has correct constant field", []() {
        HPointer nil = elm_nil();
        RC_ASSERT(nil.constant == Const_Nil);
        RC_ASSERT(elm_list_length(nil) == 0);
    });
});

Testing::Test testElmConsAllocation("Elm cons allocates a Cons cell", []() {
    rc::check("Cons cell is allocated correctly", []() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        i64 value = *rc::gen::inRange<i64>(-1000, 1000);
        HPointer list = elm_cons_int(value, elm_nil());

        RC_ASSERT(list.constant == 0);  // Not a constant.

        void* obj = fromPointer(list);
        if (!obj) RC_FAIL("fromPointer returned null");

        Cons* cons = static_cast<Cons*>(obj);
        RC_ASSERT(cons->header.tag == Tag_Cons);
        RC_ASSERT(cons->header.unboxed & 1);  // Head is unboxed.
        RC_ASSERT(cons->head.i == value);
        RC_ASSERT(cons->tail.constant == Const_Nil);
    });
});

Testing::Test testElmListFromInts("Elm list created from vector of ints", []() {
    rc::check("List from ints has correct structure", []() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        size_t len = *rc::gen::inRange<size_t>(0, 20);
        std::vector<i64> values;
        values.reserve(len);
        for (size_t i = 0; i < len; i++) {
            values.push_back(*rc::gen::inRange<i64>(-100, 100));
        }

        HPointer list = elm_list_from_ints(values);

        RC_ASSERT(elm_list_length(list) == values.size());

        std::vector<i64> extracted = elm_list_to_ints(list);
        RC_ASSERT(extracted == values);
    });
});

Testing::Test testElmReverseEmpty("Elm reverse of empty list is empty", []() {
    rc::check("Reverse of nil is nil", []() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        HPointer nil = elm_nil();
        HPointer reversed = elm_reverse(nil);

        RC_ASSERT(reversed.constant == Const_Nil);
    });
});

Testing::Test testElmReverseSingle("Elm reverse of single element list", []() {
    rc::check("Reverse of [x] is [x]", []() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        i64 value = *rc::gen::inRange<i64>(-1000, 1000);
        HPointer list = elm_cons_int(value, elm_nil());

        // Register as root to survive any GC during reverse.
        HPointer root = list;
        gc.getRootSet().addRoot(&root);

        HPointer reversed = elm_reverse(root);

        std::vector<i64> result = elm_list_to_ints(reversed);
        RC_ASSERT(result.size() == 1);
        RC_ASSERT(result[0] == value);

        gc.getRootSet().removeRoot(&root);
    });
});

Testing::Test testElmReverseMultiple("Elm reverse of multiple elements", []() {
    rc::check("Reverse of [1,2,3] is [3,2,1]", []() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        size_t len = *rc::gen::inRange<size_t>(2, 10);
        std::vector<i64> values;
        values.reserve(len);
        for (size_t i = 0; i < len; i++) {
            values.push_back(*rc::gen::inRange<i64>(-100, 100));
        }

        HPointer list = elm_list_from_ints(values);

        // Register as root.
        HPointer root = list;
        gc.getRootSet().addRoot(&root);

        HPointer reversed = elm_reverse(root);

        std::vector<i64> result = elm_list_to_ints(reversed);

        // Expected: values reversed.
        std::vector<i64> expected = values;
        std::reverse(expected.begin(), expected.end());

        RC_ASSERT(result == expected);

        gc.getRootSet().removeRoot(&root);
    });
});

Testing::Test testElmReverseSurvivesGC("Elm reversed list survives GC", []() {
    rc::check("Reversed list survives minor and major GC", []() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        std::vector<i64> values = {1, 2, 3, 4, 5};
        HPointer list = elm_list_from_ints(values);

        // Register original list as root during reverse.
        HPointer root1 = list;
        gc.getRootSet().addRoot(&root1);

        // Reverse the list (root1 keeps original alive if GC triggers).
        HPointer reversed = elm_reverse(root1);

        // Register reversed list as root.
        HPointer root2 = reversed;
        gc.getRootSet().addRoot(&root2);

        // Remove original root - we only need the reversed list now.
        gc.getRootSet().removeRoot(&root1);

        // Trigger minor GC twice to promote objects to old gen.
        // PROMOTION_AGE=1, so after first GC age becomes 1, and on second GC they're promoted.
        gc.minorGC();
        gc.minorGC();

        // Read from root2 (may have been updated by GC).
        std::vector<i64> after_minor = elm_list_to_ints(root2);
        std::vector<i64> expected = {5, 4, 3, 2, 1};
        RC_ASSERT(after_minor == expected);

        // Now objects are in old gen, so major GC should work.
        gc.majorGC();

        // Verify list is still intact.
        std::vector<i64> after_major = elm_list_to_ints(root2);
        RC_ASSERT(after_major == expected);

        gc.getRootSet().removeRoot(&root2);
    });
});

Testing::Test testElmReverseLargeList("Elm reverse of large list", []() {
    rc::check("Reverse of large list is correct", []() {
        auto& gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        // Create a list with 100-500 elements.
        size_t size = *rc::gen::inRange<size_t>(100, 500);
        std::vector<i64> values;
        values.reserve(size);
        for (size_t i = 0; i < size; i++) {
            values.push_back(static_cast<i64>(i));
        }

        HPointer list = elm_list_from_ints(values);

        // Register original as root during reverse.
        HPointer root1 = list;
        gc.getRootSet().addRoot(&root1);

        HPointer reversed = elm_reverse(root1);

        // Register reversed as root.
        HPointer root2 = reversed;
        gc.getRootSet().addRoot(&root2);

        // Remove original root.
        gc.getRootSet().removeRoot(&root1);

        // Verify length.
        RC_ASSERT(elm_list_length(root2) == size);

        // Verify first and last elements.
        std::vector<i64> result = elm_list_to_ints(root2);
        RC_ASSERT(result.size() == size);
        RC_ASSERT(result.front() == static_cast<i64>(size - 1));
        RC_ASSERT(result.back() == 0);

        gc.getRootSet().removeRoot(&root2);
    });
});
