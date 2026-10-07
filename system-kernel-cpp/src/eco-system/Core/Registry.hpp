//===- Registry.hpp - T5 main-thread registry with a GC root scanner ------===//
//
// G9 / T5 (plans/eco-system-library.md §3.3.2): a main-thread-only table of
// `int64_t id → Entry` whose long-lived heap references are stored as
// encoded `uint64_t` words and evacuated in place by an external root
// scanner.
//
// The scanner is registered lazily on first use and again whenever
// `Allocator::heapGeneration()` changes (F24): heap-reset harnesses destroy
// RootSets (and their scanners) while this static state survives, and the
// entries of a dead heap are meaningless, so they are cleared.
//
// `Entry` must provide
//     template <typename F> void forEachWord(F&& f);
// calling `f(uint64_t&)` for every encoded HPointer word it holds (zero
// words are skipped by the scanner). Variable-size entries (deques of parked
// values) are supported because the visitor walks them directly.
//
// No mutex: only the main thread touches the table (G1, G9). Never hold an
// `Entry*` across an allocation or an Elm call that may erase it (G11): look
// it up again by id.
//
// Usage:
//     struct Watch { uint64_t routerEnc = 0, taggerEnc = 0;
//         template <typename F> void forEachWord(F&& f) { f(routerEnc); f(taggerEnc); } };
//     static Registry<Watch>& watches() {
//         static auto* r = new Registry<Watch>("eco-system-watches");  // leaky (§3.4)
//         return *r;
//     }
//
// Templates used: T5.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_REGISTRY_HPP
#define ECO_SYSTEM_CORE_REGISTRY_HPP

#include "eco-system/Core/Core.hpp"
#include "allocator/RootSet.hpp"

#include <cstdint>
#include <unordered_map>
#include <utility>

namespace Eco::System {

template <typename Entry>
class Registry {
public:
    // `scannerName` must have static lifetime (a string literal).
    explicit Registry(const char* scannerName) : name_(scannerName) {}

    Registry(const Registry&) = delete;
    Registry& operator=(const Registry&) = delete;

    // The live table, after (re)registering the scanner for the current heap.
    std::unordered_map<int64_t, Entry>& map() {
        ensure();
        return m_;
    }

    // Inserts `e` under a fresh id (ids are never reused within a process).
    int64_t insert(Entry e) {
        ensure();
        int64_t id = nextId_++;
        m_.emplace(id, std::move(e));
        return id;
    }

    // nullptr if absent. Re-fetch after any allocation or Elm call (G11).
    Entry* find(int64_t id) {
        ensure();
        auto it = m_.find(id);
        return it == m_.end() ? nullptr : &it->second;
    }

    bool erase(int64_t id) {
        ensure();
        return m_.erase(id) != 0;
    }

    size_t size() {
        ensure();
        return m_.size();
    }

private:
    void ensure() {
        uint64_t g = Allocator::instance().heapGeneration();
        if (!reg_ || gen_ != g) {
            reg_ = true;
            gen_ = g;
            m_.clear();   // entries of a dead heap are meaningless
            Registry* self = this;   // leaky singleton: outlives every scanner
            Allocator::instance().getRootSet().addExternalRootScanner(
                [self](RootSet::EvacuateFn evac) {
                    for (auto& kv : self->m_) {
                        kv.second.forEachWord([&evac](uint64_t& w) {
                            if (w) evac(w);   // evacuate in place
                        });
                    }
                },
                name_);
        }
    }

    std::unordered_map<int64_t, Entry> m_;
    const char* name_;
    int64_t nextId_ = 1;
    uint64_t gen_ = 0;
    bool reg_ = false;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_REGISTRY_HPP
