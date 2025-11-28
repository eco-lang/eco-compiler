#include <algorithm>
#include "Allocator.hpp"
#include "HeapGenerators.hpp"
#include "OldGenSpace.hpp"

namespace Elm {

// ============================================================================
// Allocation Implementation
// ============================================================================

// Helper to create a constant HPointer.
static HPointer createConstant(Constant c) {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = c;
    ptr.padding = 0;
    return ptr;
}

// Helper to build unboxed bitmap for variable-sized structures.
static u64 buildUnboxedBitmap(const std::vector<bool>& boxed_flags, size_t max_bits) {
    u64 bitmap = 0;
    for (size_t i = 0; i < std::min(boxed_flags.size(), max_bits); i++) {
        if (!boxed_flags[i]) {  // Unboxed when flag is false.
            bitmap |= (1ULL << i);
        }
    }
    return bitmap;
}

// Helper to make Unboxable for ConsHeadDesc.
static Unboxable makeUnboxableFromConsHead(const ConsHeadDesc& head, const std::vector<void*>& allocated) {
    Unboxable val;
    if (head.head_boxed && !allocated.empty()) {
        size_t idx = head.child_index % allocated.size();
        val.p = AllocatorTestAccess::toPointer(allocated[idx]);
    } else if (head.head_boxed && allocated.empty()) {
        // No objects to reference, use Nil constant.
        val.p = createConstant(Const_Nil);
    } else {
        // Unboxed: use primitive value or constant based on head.unboxed.
        switch (head.unboxed) {
            case UnboxedInt:
                val.i = head.int_val;
                break;
            case UnboxedFloat:
                val.f = head.float_val;
                break;
            case UnboxedChar:
                val.c = head.char_val;
                break;
            case UnboxedUnit:
                val.p = createConstant(Const_Unit);
                break;
            case UnboxedEmptyRec:
                val.p = createConstant(Const_EmptyRec);
                break;
            case UnboxedTrue:
                val.p = createConstant(Const_True);
                break;
            case UnboxedFalse:
                val.p = createConstant(Const_False);
                break;
            case UnboxedNil:
                val.p = createConstant(Const_Nil);
                break;
            case UnboxedNothing:
                val.p = createConstant(Const_Nothing);
                break;
            case UnboxedEmptyString:
                val.p = createConstant(Const_EmptyString);
                break;
        }
    }
    return val;
}

static Unboxable makeUnboxable(bool is_boxed, const HeapObjectDesc &desc, const std::vector<void *> &allocated,
                               size_t child_index) {
    Unboxable val;

    if (is_boxed && !allocated.empty()) {
        // Boxed: pointer to existing object.
        size_t idx = child_index % allocated.size();
        val.p = AllocatorTestAccess::toPointer(allocated[idx]);
    } else if (is_boxed && allocated.empty()) {
        // No objects to reference, use Nil constant.
        val.p = createConstant(Const_Nil);
    } else {
        // Unboxed: use primitive value or constant based on desc.unboxed.
        switch (desc.unboxed) {
            case UnboxedInt:
                val.i = desc.int_val;
                break;
            case UnboxedFloat:
                val.f = desc.float_val;
                break;
            case UnboxedChar:
                val.c = desc.char_val;
                break;
            case UnboxedUnit:
                val.p = createConstant(Const_Unit);
                break;
            case UnboxedEmptyRec:
                val.p = createConstant(Const_EmptyRec);
                break;
            case UnboxedTrue:
                val.p = createConstant(Const_True);
                break;
            case UnboxedFalse:
                val.p = createConstant(Const_False);
                break;
            case UnboxedNil:
                val.p = createConstant(Const_Nil);
                break;
            case UnboxedNothing:
                val.p = createConstant(Const_Nothing);
                break;
            case UnboxedEmptyString:
                val.p = createConstant(Const_EmptyString);
                break;
        }
    }

    return val;
}

HPointer allocateList(const ListDesc& list_desc, const std::vector<void*>& allocated) {
    auto& alloc = Allocator::instance();

    // Start with Nil constant.
    HPointer tail;
    tail.ptr = 0;
    tail.constant = Const_Nil;
    tail.padding = 0;

    // Build list from end to beginning.
    for (auto it = list_desc.elements.rbegin(); it != list_desc.elements.rend(); ++it) {
        void* cons_obj = alloc.allocate(sizeof(Cons), Tag_Cons);
        Cons* cons = static_cast<Cons*>(cons_obj);
        Header* hdr = getHeader(cons_obj);

        // Set head (boxed or unboxed).
        cons->head = makeUnboxableFromConsHead(*it, allocated);

        // Set tail to previous tail.
        cons->tail = tail;

        // Set unboxed flag in header (bit 0 = head unboxed).
        hdr->unboxed = it->head_boxed ? 0 : 1;

        // Update tail for next iteration.
        tail = AllocatorTestAccess::toPointer(cons_obj);
    }

    return tail;  // Returns head of list (or Nil if empty).
}

std::vector<void *> allocateHeapGraph(const std::vector<HeapObjectDesc> &nodes) {
    auto &alloc = Allocator::instance();
    std::vector<void *> allocated;
    allocated.reserve(nodes.size());

    // Allocate all objects.
    for (const auto &desc: nodes) {
        void *obj = nullptr;

        switch (desc.type) {
            case HeapObjectDesc::Int: {
                obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
                ElmInt *elm_int = static_cast<ElmInt *>(obj);
                elm_int->value = desc.int_val;
                break;
            }

            case HeapObjectDesc::Float: {
                obj = alloc.allocate(sizeof(ElmFloat), Tag_Float);
                ElmFloat *elm_float = static_cast<ElmFloat *>(obj);
                elm_float->value = desc.float_val;
                break;
            }

            case HeapObjectDesc::Char: {
                obj = alloc.allocate(sizeof(ElmChar), Tag_Char);
                ElmChar *elm_char = static_cast<ElmChar *>(obj);
                elm_char->value = desc.char_val;
                break;
            }

            case HeapObjectDesc::String: {
                // Empty strings should use Const_EmptyString, not heap allocation.
                // Generator should prevent this, but assert for safety.
                if (desc.string_chars.empty()) {
                    std::cerr << "ERROR: Empty string generated - should use Const_EmptyString" << std::endl;
                    std::abort();
                }

                size_t size = sizeof(ElmString) + desc.string_chars.size() * sizeof(u16);
                obj = alloc.allocate(size, Tag_String);
                ElmString *elm_string = static_cast<ElmString *>(obj);
                for (size_t i = 0; i < desc.string_chars.size(); i++) {
                    elm_string->chars[i] = desc.string_chars[i];
                }
                break;
            }

            case HeapObjectDesc::Tuple2: {
                obj = alloc.allocate(sizeof(Tuple2), Tag_Tuple2);
                Tuple2 *tuple = static_cast<Tuple2 *>(obj);
                Header *hdr = getHeader(obj);

                // Create fields (may reference previously allocated objects).
                tuple->a = makeUnboxable(desc.a_boxed, desc, allocated, desc.child_a);
                tuple->b = makeUnboxable(desc.b_boxed, desc, allocated, desc.child_b);

                // Set unboxed flags.
                hdr->unboxed = 0;
                if (!desc.a_boxed)
                    hdr->unboxed |= 1;
                if (!desc.b_boxed)
                    hdr->unboxed |= 2;
                break;
            }

            case HeapObjectDesc::Tuple3: {
                obj = alloc.allocate(sizeof(Tuple3), Tag_Tuple3);
                Tuple3 *tuple = static_cast<Tuple3 *>(obj);
                Header *hdr = getHeader(obj);

                // Create fields (may reference previously allocated objects).
                tuple->a = makeUnboxable(desc.a_boxed, desc, allocated, desc.child_a);
                tuple->b = makeUnboxable(desc.b_boxed, desc, allocated, desc.child_b);
                tuple->c = makeUnboxable(desc.c_boxed, desc, allocated, desc.child_c);

                // Set unboxed flags.
                hdr->unboxed = 0;
                if (!desc.a_boxed)
                    hdr->unboxed |= 1;
                if (!desc.b_boxed)
                    hdr->unboxed |= 2;
                if (!desc.c_boxed)
                    hdr->unboxed |= 4;
                break;
            }

            case HeapObjectDesc::Custom: {
                size_t num_values = std::min(desc.custom_values_boxed.size(), desc.custom_child_values.size());
                size_t size = sizeof(Custom) + num_values * sizeof(Unboxable);
                obj = alloc.allocate(size, Tag_Custom);
                Custom *custom = static_cast<Custom *>(obj);

                custom->ctor = desc.ctor;
                custom->unboxed = buildUnboxedBitmap(desc.custom_values_boxed, 48);

                for (size_t i = 0; i < num_values; i++) {
                    custom->values[i] = makeUnboxable(desc.custom_values_boxed[i], desc, allocated,
                                                      desc.custom_child_values[i]);
                }
                break;
            }

            case HeapObjectDesc::Record: {
                size_t num_values = std::min(desc.record_values_boxed.size(), desc.record_child_values.size());
                size_t size = sizeof(Record) + num_values * sizeof(Unboxable);
                obj = alloc.allocate(size, Tag_Record);
                Record *record = static_cast<Record *>(obj);

                record->unboxed = buildUnboxedBitmap(desc.record_values_boxed, 64);

                for (size_t i = 0; i < num_values; i++) {
                    record->values[i] = makeUnboxable(desc.record_values_boxed[i], desc, allocated,
                                                      desc.record_child_values[i]);
                }
                break;
            }

            case HeapObjectDesc::DynRecord: {
                size_t num_values = desc.dynrec_child_values.size();
                size_t size = sizeof(DynRecord) + num_values * sizeof(HPointer);
                obj = alloc.allocate(size, Tag_DynRecord);
                DynRecord *dynrec = static_cast<DynRecord *>(obj);

                dynrec->unboxed = 0;  // DynRecord values are all HPointers.

                // Set fieldgroup reference (clamp to valid range or use default).
                if (!allocated.empty() && desc.dynrec_child_fieldgroup < allocated.size()) {
                    dynrec->fieldgroup = AllocatorTestAccess::toPointer(allocated[desc.dynrec_child_fieldgroup]);
                } else {
                    // Create Nil constant if no valid fieldgroup.
                    dynrec->fieldgroup.ptr = 0;
                    dynrec->fieldgroup.constant = Const_Nil;
                    dynrec->fieldgroup.padding = 0;
                }

                for (size_t i = 0; i < num_values; i++) {
                    if (!allocated.empty()) {
                        size_t idx = desc.dynrec_child_values[i] % allocated.size();
                        dynrec->values[i] = AllocatorTestAccess::toPointer(allocated[idx]);
                    } else {
                        dynrec->values[i].ptr = 0;
                        dynrec->values[i].constant = Const_Nil;
                        dynrec->values[i].padding = 0;
                    }
                }
                break;
            }

            case HeapObjectDesc::FieldGroup: {
                size_t num_fields = desc.fieldgroup_ids.size();
                size_t size = sizeof(FieldGroup) + num_fields * sizeof(u32);
                obj = alloc.allocate(size, Tag_FieldGroup);
                FieldGroup *fieldgroup = static_cast<FieldGroup *>(obj);

                fieldgroup->count = num_fields;
                for (size_t i = 0; i < num_fields; i++) {
                    fieldgroup->fields[i] = desc.fieldgroup_ids[i];
                }
                break;
            }

            case HeapObjectDesc::Closure: {
                size_t num_values = std::min(desc.closure_values_boxed.size(), desc.closure_child_values.size());
                size_t size = sizeof(Closure) + num_values * sizeof(Unboxable);
                obj = alloc.allocate(size, Tag_Closure);
                Closure *closure = static_cast<Closure *>(obj);

                closure->n_values = num_values;
                closure->max_values = num_values;
                closure->unboxed = buildUnboxedBitmap(desc.closure_values_boxed, 52);
                closure->evaluator = (EvalFunction)desc.closure_evaluator_dummy;

                for (size_t i = 0; i < num_values; i++) {
                    closure->values[i] = makeUnboxable(desc.closure_values_boxed[i], desc, allocated,
                                                       desc.closure_child_values[i]);
                }
                break;
            }
        }

        if (obj) {
            allocated.push_back(obj);
        }
    }

    return allocated;
}

std::vector<void *> allocateHeapGraphInOldGen(OldGenSpace& oldgen,
                                               const std::vector<HeapObjectDesc> &nodes) {
    std::vector<void *> allocated;
    allocated.reserve(nodes.size());

    // Helper lambda for allocating and initializing header in old gen.
    auto allocInOldGen = [&oldgen](size_t size, Tag tag) -> void* {
        void* obj = oldgen.allocate(size);
        if (obj) {
            Header* hdr = getHeader(obj);
            hdr->tag = tag;
            // Note: Don't overwrite color - allocate() already set it correctly
            // based on current GC phase (Black during marking/sweeping, White otherwise).
            hdr->age = 0;
            hdr->unboxed = 0;
        }
        return obj;
    };

    // Allocate all objects.
    for (const auto &desc: nodes) {
        void *obj = nullptr;

        switch (desc.type) {
            case HeapObjectDesc::Int: {
                obj = allocInOldGen(sizeof(ElmInt), Tag_Int);
                if (!obj) break;
                ElmInt *elm_int = static_cast<ElmInt *>(obj);
                elm_int->value = desc.int_val;
                break;
            }

            case HeapObjectDesc::Float: {
                obj = allocInOldGen(sizeof(ElmFloat), Tag_Float);
                if (!obj) break;
                ElmFloat *elm_float = static_cast<ElmFloat *>(obj);
                elm_float->value = desc.float_val;
                break;
            }

            case HeapObjectDesc::Char: {
                obj = allocInOldGen(sizeof(ElmChar), Tag_Char);
                if (!obj) break;
                ElmChar *elm_char = static_cast<ElmChar *>(obj);
                elm_char->value = desc.char_val;
                break;
            }

            case HeapObjectDesc::String: {
                // Empty strings should use Const_EmptyString, not heap allocation.
                if (desc.string_chars.empty()) {
                    std::cerr << "ERROR: Empty string generated - should use Const_EmptyString" << std::endl;
                    std::abort();
                }

                size_t size = sizeof(ElmString) + desc.string_chars.size() * sizeof(u16);
                obj = allocInOldGen(size, Tag_String);
                if (!obj) break;
                ElmString *elm_string = static_cast<ElmString *>(obj);
                Header* hdr = getHeader(obj);
                hdr->size = desc.string_chars.size();  // Required for getObjectSize()
                for (size_t i = 0; i < desc.string_chars.size(); i++) {
                    elm_string->chars[i] = desc.string_chars[i];
                }
                break;
            }

            case HeapObjectDesc::Tuple2: {
                obj = allocInOldGen(sizeof(Tuple2), Tag_Tuple2);
                if (!obj) break;
                Tuple2 *tuple = static_cast<Tuple2 *>(obj);
                Header *hdr = getHeader(obj);

                // Create fields (may reference previously allocated objects).
                tuple->a = makeUnboxable(desc.a_boxed, desc, allocated, desc.child_a);
                tuple->b = makeUnboxable(desc.b_boxed, desc, allocated, desc.child_b);

                // Set unboxed flags.
                hdr->unboxed = 0;
                if (!desc.a_boxed)
                    hdr->unboxed |= 1;
                if (!desc.b_boxed)
                    hdr->unboxed |= 2;
                break;
            }

            case HeapObjectDesc::Tuple3: {
                obj = allocInOldGen(sizeof(Tuple3), Tag_Tuple3);
                if (!obj) break;
                Tuple3 *tuple = static_cast<Tuple3 *>(obj);
                Header *hdr = getHeader(obj);

                // Create fields (may reference previously allocated objects).
                tuple->a = makeUnboxable(desc.a_boxed, desc, allocated, desc.child_a);
                tuple->b = makeUnboxable(desc.b_boxed, desc, allocated, desc.child_b);
                tuple->c = makeUnboxable(desc.c_boxed, desc, allocated, desc.child_c);

                // Set unboxed flags.
                hdr->unboxed = 0;
                if (!desc.a_boxed)
                    hdr->unboxed |= 1;
                if (!desc.b_boxed)
                    hdr->unboxed |= 2;
                if (!desc.c_boxed)
                    hdr->unboxed |= 4;
                break;
            }

            case HeapObjectDesc::Custom: {
                size_t num_values = std::min(desc.custom_values_boxed.size(), desc.custom_child_values.size());
                size_t size = sizeof(Custom) + num_values * sizeof(Unboxable);
                obj = allocInOldGen(size, Tag_Custom);
                if (!obj) break;
                Custom *custom = static_cast<Custom *>(obj);
                Header* hdr = getHeader(obj);
                hdr->size = num_values;  // Required for getObjectSize()

                custom->ctor = desc.ctor;
                custom->unboxed = buildUnboxedBitmap(desc.custom_values_boxed, 48);

                for (size_t i = 0; i < num_values; i++) {
                    custom->values[i] = makeUnboxable(desc.custom_values_boxed[i], desc, allocated,
                                                      desc.custom_child_values[i]);
                }
                break;
            }

            case HeapObjectDesc::Record: {
                size_t num_values = std::min(desc.record_values_boxed.size(), desc.record_child_values.size());
                size_t size = sizeof(Record) + num_values * sizeof(Unboxable);
                obj = allocInOldGen(size, Tag_Record);
                if (!obj) break;
                Record *record = static_cast<Record *>(obj);
                Header* hdr = getHeader(obj);
                hdr->size = num_values;  // Required for getObjectSize()

                record->unboxed = buildUnboxedBitmap(desc.record_values_boxed, 64);

                for (size_t i = 0; i < num_values; i++) {
                    record->values[i] = makeUnboxable(desc.record_values_boxed[i], desc, allocated,
                                                      desc.record_child_values[i]);
                }
                break;
            }

            case HeapObjectDesc::DynRecord: {
                size_t num_values = desc.dynrec_child_values.size();
                size_t size = sizeof(DynRecord) + num_values * sizeof(HPointer);
                obj = allocInOldGen(size, Tag_DynRecord);
                if (!obj) break;
                DynRecord *dynrec = static_cast<DynRecord *>(obj);
                Header* hdr = getHeader(obj);
                hdr->size = num_values;  // Required for getObjectSize()

                dynrec->unboxed = 0;  // DynRecord values are all HPointers.

                // Set fieldgroup reference (clamp to valid range or use default).
                if (!allocated.empty() && desc.dynrec_child_fieldgroup < allocated.size()) {
                    dynrec->fieldgroup = AllocatorTestAccess::toPointer(allocated[desc.dynrec_child_fieldgroup]);
                } else {
                    // Create Nil constant if no valid fieldgroup.
                    dynrec->fieldgroup.ptr = 0;
                    dynrec->fieldgroup.constant = Const_Nil;
                    dynrec->fieldgroup.padding = 0;
                }

                for (size_t i = 0; i < num_values; i++) {
                    if (!allocated.empty()) {
                        size_t idx = desc.dynrec_child_values[i] % allocated.size();
                        dynrec->values[i] = AllocatorTestAccess::toPointer(allocated[idx]);
                    } else {
                        dynrec->values[i].ptr = 0;
                        dynrec->values[i].constant = Const_Nil;
                        dynrec->values[i].padding = 0;
                    }
                }
                break;
            }

            case HeapObjectDesc::FieldGroup: {
                size_t num_fields = desc.fieldgroup_ids.size();
                size_t size = sizeof(FieldGroup) + num_fields * sizeof(u32);
                obj = allocInOldGen(size, Tag_FieldGroup);
                if (!obj) break;
                FieldGroup *fieldgroup = static_cast<FieldGroup *>(obj);
                Header* hdr = getHeader(obj);
                hdr->size = num_fields;  // Required for getObjectSize()

                fieldgroup->count = num_fields;
                for (size_t i = 0; i < num_fields; i++) {
                    fieldgroup->fields[i] = desc.fieldgroup_ids[i];
                }
                break;
            }

            case HeapObjectDesc::Closure: {
                size_t num_values = std::min(desc.closure_values_boxed.size(), desc.closure_child_values.size());
                size_t size = sizeof(Closure) + num_values * sizeof(Unboxable);
                obj = allocInOldGen(size, Tag_Closure);
                if (!obj) break;
                Closure *closure = static_cast<Closure *>(obj);

                closure->n_values = num_values;
                closure->max_values = num_values;
                closure->unboxed = buildUnboxedBitmap(desc.closure_values_boxed, 52);
                closure->evaluator = (EvalFunction)desc.closure_evaluator_dummy;

                for (size_t i = 0; i < num_values; i++) {
                    closure->values[i] = makeUnboxable(desc.closure_values_boxed[i], desc, allocated,
                                                       desc.closure_child_values[i]);
                }
                break;
            }
        }

        if (obj) {
            allocated.push_back(obj);
        }
    }

    return allocated;
}

} // namespace Elm
