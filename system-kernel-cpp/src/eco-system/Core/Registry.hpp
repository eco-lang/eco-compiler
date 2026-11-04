//===- Registry.hpp - Eco-thread table of entries that hold heap references -------===//
//
// C++ state that must keep Elm heap values across calls cannot hold them as raw pointers, because the
// collector moves objects and frees what it cannot reach. A `Registry` is a table that gives such
// state a home: each entry is stored under an `int64_t` id, its heap references are kept as encoded
// HPointer words, and the registry reports those words to the collector, which keeps the values alive
// and updates each word in place when it moves the value.
//
// The reporting is done by an external root scanner, as `RootSet::addExternalRootScanner` describes.
// A heap reset destroys the root sets and their scanners, while a registry, which must live for the
// whole process, survives it. Every member function therefore first compares `Allocator::heapGeneration()` with the
// generation it last saw. On the first call, and whenever the generation has changed, it discards
// every entry, since their words refer to a heap that no longer exists, and registers its scanner
// with the current root set.
//
// The scanner keeps a pointer to the registry, so a registry must never be destroyed: create it with
// `new` and never delete it, as in the usage below. Copying is refused.
//
// There is no mutex. The table is meant for the eco thread, the thread that runs the Elm scheduler,
// which is also the thread on which the collector calls the scanner.
//
// Usage:
//     struct Watch { uint64_t routerEnc = 0, taggerEnc = 0;
//         template <typename F> void forEachWord(F&& f) { f(routerEnc); f(taggerEnc); } };
//     static Registry<Watch>& watches() {
//         static auto* r = new Registry<Watch>("eco-system-watches");  // never deleted
//         return *r;
//     }
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

/// A table of `Entry` values keyed by `int64_t` id, whose heap references the collector keeps alive
/// and updates, and which empties itself when the heap is reset.
///
/// `Entry` must be movable and provide
///     template <typename F> void forEachWord(F&& f);
/// which calls `f(uint64_t&)` on every encoded HPointer word the entry holds. The words a call
/// reports are the ones the collector keeps alive, so an entry must report every word it stores,
/// however many it holds at the time; a word that is zero is skipped. Nothing checks this.
///
/// Ids are handed out in increasing order from 1 and are never reused by the same registry, including
/// across heap resets, which discard entries but not the id counter.
template <typename Entry>
class Registry {
public:
    /// Creates an empty registry whose scanner is labelled `scannerName` in the collector's statistics.
    /// The pointer is kept, so `scannerName` must have static lifetime, such as a string literal. The
    /// scanner is registered on the first call to any other member, not here.
    explicit Registry(const char* scannerName) : name_(scannerName) {}

    Registry(const Registry&) = delete;
    Registry& operator=(const Registry&) = delete;

    /// Returns the table itself, for iteration or direct changes. Words stored in it are scanned like
    /// those added through `insert`.
    ///
    /// The reference stays valid for the registry's lifetime, but a later call to any member empties the
    /// table if the heap has been reset in between. Ids placed in it directly do not advance the id
    /// counter, so they may collide with ids `insert` hands out.
    std::unordered_map<int64_t, Entry>& map() {
        ensure();
        return m_;
    }

    /// Stores `e` under a new id and returns the id.
    int64_t insert(Entry e) {
        ensure();
        int64_t id = nextId_++;
        m_.emplace(id, std::move(e));
        return id;
    }

    /// Returns the entry stored under `id`, or null if there is none.
    ///
    /// The pointer is invalidated when the entry is erased, and when the next call after a heap reset
    /// empties the table. Code that erases from this registry, resets the heap or calls back into Elm
    /// in between may cause either, so look the entry up again by id afterwards.
    Entry* find(int64_t id) {
        ensure();
        auto it = m_.find(id);
        return it == m_.end() ? nullptr : &it->second;
    }

    /// Removes the entry stored under `id`, and returns whether there was one.
    bool erase(int64_t id) {
        ensure();
        return m_.erase(id) != 0;
    }

    /// Returns the number of entries in the table.
    size_t size() {
        ensure();
        return m_.size();
    }

private:
    /// Empties the table and registers the scanner, on the first call and whenever the heap generation
    /// has changed since the last one; does nothing otherwise.
    void ensure() {
        uint64_t g = Allocator::instance().heapGeneration();
        if (!reg_ || gen_ != g) {
            reg_ = true;
            gen_ = g;
            m_.clear();
            Registry* self = this;   // the registry is never destroyed, so it outlives every scanner
            Allocator::instance().getRootSet().addExternalRootScanner(
                [self](RootSet::EvacuateFn evac) {
                    for (auto& kv : self->m_) {
                        kv.second.forEachWord([&evac](uint64_t& w) {
                            if (w) evac(w);
                        });
                    }
                },
                name_);
        }
    }

    std::unordered_map<int64_t, Entry> m_;
    const char* name_;  ///< The scanner's label; static lifetime, not owned.
    int64_t nextId_ = 1;
    uint64_t gen_ = 0;  ///< The heap generation the scanner was last registered for.
    bool reg_ = false;  ///< Whether the scanner has been registered at all; `gen_` is meaningful only once it has.
};

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_REGISTRY_HPP
