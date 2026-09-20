//===- CellStore.cpp - Off-heap mutable cell vectors ---------------------===//
//
// See CellStore.hpp for why this lives off the Elm heap.
//
// Layout: a global table of stores, indexed by handle. A disposed slot is
// nulled but never reused, so a stale handle aborts rather than aliasing a
// different store.
//
// The trail records (index, previous word) for every write made while at
// least one mark is open, plus the cell count at each mark. Rollback restores
// the recorded words in reverse and truncates back to the recorded count;
// pushes made inside the scope are dropped by the truncation, and writes to
// cells that did not exist at the mark are skipped (their cell is going away).
// With no mark open, writes are not trailed at all — the common case.
//
//===----------------------------------------------------------------------===//

#include "CellStore.hpp"
#include "ExportHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RootSet.hpp"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <utility>
#include <vector>

namespace Eco::Kernel::CellStore {

namespace {

struct Store {
    std::vector<uint64_t> cells;
    // (cell index, word held before the write that trailed it)
    std::vector<std::pair<int64_t, uint64_t>> trail;
    // (trail length, cell count) captured at each open mark
    std::vector<std::pair<size_t, size_t>> marks;
};

std::vector<std::unique_ptr<Store>> g_stores;

[[noreturn]] void fail(const char *what, int64_t h) {
    std::fprintf(stderr, "Eco.CellStore: %s (handle %lld)\n", what,
                 static_cast<long long>(h));
    std::abort();
}

Store &live(int64_t h) {
    if (h < 0 || static_cast<size_t>(h) >= g_stores.size()) {
        fail("handle out of range", h);
    }
    Store *s = g_stores[static_cast<size_t>(h)].get();
    if (s == nullptr) {
        fail("use after dispose", h);
    }
    return *s;
}

} // namespace

int64_t newStore(int64_t cap) {
    auto s = std::make_unique<Store>();
    s->cells.reserve(cap > 0 ? static_cast<size_t>(cap) : 64);
    g_stores.push_back(std::move(s));
    return static_cast<int64_t>(g_stores.size()) - 1;
}

int64_t size(int64_t h) {
    return static_cast<int64_t>(live(h).cells.size());
}

uint64_t get(int64_t ix, int64_t h) {
    Store &s = live(h);
    if (ix < 0 || static_cast<size_t>(ix) >= s.cells.size()) {
        fail("get index out of range", h);
    }
    return s.cells[static_cast<size_t>(ix)];
}

int64_t set(int64_t ix, uint64_t word, int64_t h) {
    Store &s = live(h);
    if (ix < 0 || static_cast<size_t>(ix) >= s.cells.size()) {
        fail("set index out of range", h);
    }
    if (!s.marks.empty()) {
        s.trail.emplace_back(ix, s.cells[static_cast<size_t>(ix)]);
    }
    s.cells[static_cast<size_t>(ix)] = word;
    return h;
}

int64_t push(uint64_t word, int64_t h) {
    live(h).cells.push_back(word);
    return h;
}

int64_t pushMark(int64_t h) {
    Store &s = live(h);
    s.marks.emplace_back(s.trail.size(), s.cells.size());
    return h;
}

int64_t rollback(int64_t h) {
    Store &s = live(h);
    if (s.marks.empty()) {
        fail("rollback without a mark", h);
    }
    const auto [trail_len, cell_count] = s.marks.back();
    s.marks.pop_back();
    while (s.trail.size() > trail_len) {
        const auto [ix, word] = s.trail.back();
        s.trail.pop_back();
        // A write to a cell that did not exist at the mark needs no restore:
        // the truncation below removes the cell entirely.
        if (static_cast<size_t>(ix) < cell_count) {
            s.cells[static_cast<size_t>(ix)] = word;
        }
    }
    s.cells.resize(cell_count);
    if (s.marks.empty()) {
        s.trail.clear();
    }
    return h;
}

int64_t commit(int64_t h) {
    Store &s = live(h);
    if (s.marks.empty()) {
        fail("commit without a mark", h);
    }
    s.marks.pop_back();
    if (s.marks.empty()) {
        s.trail.clear();
    }
    return h;
}

uint64_t disposeThen(int64_t h, uint64_t x) {
    if (h >= 0 && static_cast<size_t>(h) < g_stores.size()) {
        g_stores[static_cast<size_t>(h)].reset();
    }
    return x;
}

void registerGcRootScanner() {
    Elm::Allocator::instance().getRootSet().addExternalRootScanner(
        [](Elm::RootSet::EvacuateFn evacuate) {
            for (auto &sp : g_stores) {
                if (!sp) {
                    continue;
                }
                for (uint64_t &w : sp->cells) {
                    if (w != 0) {
                        evacuate(w);
                    }
                }
                // Trailed words are values a rollback may restore, so they are
                // live even though no cell currently holds them.
                for (auto &entry : sp->trail) {
                    if (entry.second != 0) {
                        evacuate(entry.second);
                    }
                }
            }
        });
}

} // namespace Eco::Kernel::CellStore
