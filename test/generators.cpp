#include "generators.hpp"
#include <random>
#include <rapidcheck.h>
#include <vector>
#include "allocator.hpp"
#include "heap.hpp"

using namespace Elm;

// Helper functions to create random heap objects
// These are NOT RapidCheck generators - they use RNG directly

void *createRandomPrimitive(std::mt19937 &rng) {
    auto &gc = GarbageCollector::instance();
    std::uniform_int_distribution<int> type_dist(0, 2);
    int type = type_dist(rng);

    switch (type) {
        case 0: { // Int
            void *obj = gc.allocate(sizeof(ElmInt), Tag_Int);
            ElmInt *elm_int = static_cast<ElmInt *>(obj);
            std::uniform_int_distribution<i64> val_dist;
            elm_int->value = val_dist(rng);
            return obj;
        }
        case 1: { // Float
            void *obj = gc.allocate(sizeof(ElmFloat), Tag_Float);
            ElmFloat *elm_float = static_cast<ElmFloat *>(obj);
            std::uniform_real_distribution<f64> val_dist;
            elm_float->value = val_dist(rng);
            return obj;
        }
        case 2: { // Char
            void *obj = gc.allocate(sizeof(ElmChar), Tag_Char);
            ElmChar *elm_char = static_cast<ElmChar *>(obj);
            std::uniform_int_distribution<u16> val_dist(0, 0xFFFF);
            elm_char->value = val_dist(rng);
            return obj;
        }
        default:
            return nullptr;
    }
}

Unboxable createRandomUnboxable(std::mt19937 &rng, const std::vector<void *> &existing_objects, bool &is_boxed) {
    Unboxable val;
    std::uniform_int_distribution<int> coin(0, 1);

    // Randomly decide: boxed pointer or unboxed primitive
    if (coin(rng) && !existing_objects.empty()) {
        // Boxed: pointer to existing object
        is_boxed = true;
        std::uniform_int_distribution<size_t> idx_dist(0, existing_objects.size() - 1);
        size_t idx = idx_dist(rng);
        val.p = toPointer(existing_objects[idx]);
    } else {
        // Unboxed: primitive value
        is_boxed = false;
        std::uniform_int_distribution<int> type_dist(0, 2);
        int type = type_dist(rng);
        switch (type) {
            case 0: {
                std::uniform_int_distribution<i64> val_dist;
                val.i = val_dist(rng);
                break;
            }
            case 1: {
                std::uniform_real_distribution<f64> val_dist;
                val.f = val_dist(rng);
                break;
            }
            default: {
                std::uniform_int_distribution<u16> val_dist(0, 0xFFFF);
                val.c = val_dist(rng);
                break;
            }
        }
    }

    return val;
}

void *createRandomComposite(std::mt19937 &rng, const std::vector<void *> &existing_objects) {
    auto &gc = GarbageCollector::instance();
    std::uniform_int_distribution<int> type_dist(0, 1);
    int type = type_dist(rng);

    switch (type) {
        case 0: { // Tuple2
            void *obj = gc.allocate(sizeof(Tuple2), Tag_Tuple2);
            Tuple2 *tuple = static_cast<Tuple2 *>(obj);
            Header *hdr = getHeader(obj);

            bool a_boxed = false, b_boxed = false;
            tuple->a = createRandomUnboxable(rng, existing_objects, a_boxed);
            tuple->b = createRandomUnboxable(rng, existing_objects, b_boxed);

            hdr->unboxed = 0;
            if (!a_boxed)
                hdr->unboxed |= 1;
            if (!b_boxed)
                hdr->unboxed |= 2;

            return obj;
        }
        case 1: { // Tuple3
            void *obj = gc.allocate(sizeof(Tuple3), Tag_Tuple3);
            Tuple3 *tuple = static_cast<Tuple3 *>(obj);
            Header *hdr = getHeader(obj);

            bool a_boxed = false, b_boxed = false, c_boxed = false;
            tuple->a = createRandomUnboxable(rng, existing_objects, a_boxed);
            tuple->b = createRandomUnboxable(rng, existing_objects, b_boxed);
            tuple->c = createRandomUnboxable(rng, existing_objects, c_boxed);

            hdr->unboxed = 0;
            if (!a_boxed)
                hdr->unboxed |= 1;
            if (!b_boxed)
                hdr->unboxed |= 2;
            if (!c_boxed)
                hdr->unboxed |= 4;

            return obj;
        }
        default:
            return nullptr;
    }
}
