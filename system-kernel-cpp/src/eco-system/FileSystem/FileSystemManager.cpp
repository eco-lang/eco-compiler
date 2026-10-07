//===- FileSystemManager.cpp - The C++ effect manager of `System.File` ----===//
//
// plans/eco-system-library.md §3.6, Phase 4 step 4.5 and Appendix C.0 /
// C.2. Layout: FileSystemManager.hpp.
//
//   * onEffects: the subscriptions are grouped by registry key
//     (path, recursive), each holding its list of encoded taggers. One
//     WatchService watch exists per key. A key that appears starts a watch
//     and, if the path could be watched, takes one pendingAsync count (an
//     active watch keeps the program alive, §3.4); a key that disappears
//     stops its watch and releases the count. A path that cannot be watched
//     produces no events and holds no count (gren ignores watch errors).
//   * subMap composes the tagger (TimeEffectManager pattern): a 3-slot
//     closure capturing (f, oldTagger) applied to the event tuple.
//   * Delivery (T8/G12): the watch drain (one eco/system async source)
//     maps each POD WatchEvent to its key's taggers, snapshots them into one
//     rooted range, builds ( kind, Maybe relativePath ), calls each tagger,
//     then sendToApp + drain() per message.
//   * Windows: a Watch subscription crashes with a clear message (§1).
//
// Templates used: T6 (manager, rooted registration per G14), T5 (state),
// T8/G12 (delivery), G6 (one root range for the tagger snapshot).
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/FileSystemManager.hpp"

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/FileSystem/WatchService.hpp"

#include <map>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System {

namespace {

using namespace FileSystemManager;
using Fs::WatchEvent;
using Fs::WatchService;

using WatchKey = std::pair<std::string, bool>;   // (path, recursive)

struct WatchEntry {
    int64_t watchId = 0;    // 0: the path could not be watched
    bool counted = false;   // holds one pendingAsync count
    std::vector<uint64_t> taggers;   // encoded taggers
};

struct ManagerState {
    uint64_t routerEnc = 0;
    std::map<WatchKey, WatchEntry> watches;

    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : watches)
            for (auto& w : kv.second.taggers) f(w);
    }
};

Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-file-manager");   // leaky
    return *r;
}

// The single state entry (re-created after a heap reset, F24).
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

// --- Delivery ----------------------------------------------------------------

// T8 for every tagger of the event's watch. The taggers are snapshotted
// first: update may change the subscriptions while we deliver (G11).
void deliver(const WatchEvent& ev) {
    ManagerState& st = state();
    if (st.routerEnc == 0) return;
    const WatchEntry* entry = nullptr;
    for (auto& kv : st.watches) {
        if (kv.second.watchId == ev.watchId) {
            entry = &kv.second;
            break;
        }
    }
    if (!entry || entry->taggers.empty()) return;

    std::vector<HPointer> taggers;
    taggers.reserve(entry->taggers.size());
    for (uint64_t w : entry->taggers) taggers.push_back(dec(w));
    HPointer router = dec(st.routerEnc);
    HPointer str = alloc::listNil();
    HPointer arg = alloc::listNil();
    HPointer msg = alloc::listNil();
    // No allocation since the decodes above.
    Elm::StackRootGuard g({&router, &str, &arg, &msg});
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(taggers.data(), taggers.size(), ~0ULL);
    for (size_t i = 0; i < taggers.size(); ++i) {
        if (ev.hasPath) {
            str = alloc::allocStringFromUTF8(ev.path);
            // `just` allocates while its argument is rooted (`str`); its fresh
            // result goes straight into tuple2, which roots it (G4).
            arg = alloc::tuple2(alloc::unboxedInt(ev.kind),
                                alloc::boxed(alloc::just(alloc::boxed(str), true)), 0x1);
        } else {
            arg = alloc::tuple2(alloc::unboxedInt(ev.kind), alloc::boxed(alloc::nothing()), 0x1);
        }
        msg = Scheduler::callClosure1(taggers[i], arg);   // Elm call (G11)
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();                    // once per message (G12)
    }
    rs.restoreStackRangePoint(saved);
}

void watchDrain() {
    std::vector<WatchEvent> evs;
    WatchService::instance().drain(evs);
    for (auto& ev : evs) {
        try {
            deliver(ev);
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in System.File watch delivery");
        }
    }
}

bool watchReady() {
    return WatchService::instance().hasEvents();
}

// --- Manager closures (C.0) ----------------------------------------------------

// init : Task Never ()  (a 0-arity thunk, forced by setupEffects)
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

void stopWatch(WatchEntry& e) {
    if (e.watchId != 0) WatchService::instance().remove(e.watchId);
    if (e.counted) Scheduler::instance().decrementPendingAsync();
    e.watchId = 0;
    e.counted = false;
}

// onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &subs);

    // A non-allocating walk (G5): copy every field out.
    std::map<WatchKey, std::vector<uint64_t>> wanted;
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        if (!obj) continue;
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor != CTOR_WATCH) continue;
        std::string path = toStdString(sub->values[WATCH_PATH_FIELD].p);
        bool recursive = alloc::boolValue(sub->values[WATCH_RECURSIVE_FIELD].p);
        wanted[WatchKey{std::move(path), recursive}].push_back(enc(sub->values[WATCH_TAGGER_FIELD].p));
    }

#if defined(_WIN32)
    if (!wanted.empty())
        ::Eco::Kernel::reportFatal("eco/system: System.File.watch is not supported on Windows yet");
#endif

    // Registry update and service calls: POD only, no heap allocation while
    // `st` is live.
    {
        ManagerState& st = state();
        st.routerEnc = enc(router);
        for (auto it = st.watches.begin(); it != st.watches.end();) {
            if (wanted.find(it->first) == wanted.end()) {
                stopWatch(it->second);
                it = st.watches.erase(it);
            } else {
                ++it;
            }
        }
        for (auto& kv : wanted) {
            auto it = st.watches.find(kv.first);
            if (it == st.watches.end()) {
                WatchEntry e;
                e.watchId = WatchService::instance().add(kv.first.first, kv.first.second);
                if (e.watchId != 0) {
                    addDrainSource(&watchDrain, &watchReady);   // idempotent
                    Scheduler::instance().incrementPendingAsync();
                    e.counted = true;
                }
                it = st.watches.emplace(kv.first, std::move(e)).first;
            }
            it->second.taggers = std::move(kv.second);
        }
    }

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onSelfMsg : Router -> Never -> () -> Task Never ()  (never sent)
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// The composed tagger of subMap: args[0] = f, args[1] = old tagger,
// args[2] = the event tuple. Result: f (old event).
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer old = dec(args[1]);
    HPointer event = dec(args[2]);
    HPointer mid = alloc::listNil();
    Elm::StackRootGuard g({&f, &old, &event, &mid});
    mid = Scheduler::callClosure1(old, event);           // Elm call (G11)
    HPointer out = Scheduler::callClosure1(f, mid);
    return reinterpret_cast<void*>(enc(out));
}

// subMap : (a -> b) -> MySub a -> MySub b
void* subMapEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer sub = dec(args[1]);
    HPointer path = alloc::listNil();
    HPointer recursive = alloc::listNil();
    HPointer old = alloc::listNil();
    HPointer composed = alloc::listNil();
    Elm::StackRootGuard g({&f, &sub, &path, &recursive, &old, &composed});
    {
        Custom* s = static_cast<Custom*>(Allocator::instance().resolve(sub));   // no allocation in scope
        if (!s || s->ctor != CTOR_WATCH) return reinterpret_cast<void*>(enc(sub));
        path = s->values[WATCH_PATH_FIELD].p;
        recursive = s->values[WATCH_RECURSIVE_FIELD].p;
        old = s->values[WATCH_TAGGER_FIELD].p;
    }
    composed = alloc::allocClosure(&composedTaggerEval, 3);
    {
        // Both captures right after the allocation, nothing allocated in between (G8).
        void* p = Allocator::instance().resolve(composed);
        alloc::closureCapture(p, alloc::boxed(f), true);
        alloc::closureCapture(p, alloc::boxed(old), true);
    }
    std::vector<Unboxable> fields{alloc::boxed(path), alloc::boxed(recursive), alloc::boxed(composed)};
    return reinterpret_cast<void*>(enc(alloc::custom(CTOR_WATCH, fields, 0)));
}

} // namespace

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Allocates the manager closures in the rooted PortRuntime form (G14) and
// registers them under "System.File". No commands: cmdMap is nil.
void registerFileManager() {
    HPointer initCl = alloc::listNil();
    HPointer effCl = alloc::listNil();
    HPointer selfCl = alloc::listNil();
    HPointer subMapCl = alloc::listNil();
    Elm::StackRootGuard g({&initCl, &effCl, &selfCl, &subMapCl});
    initCl = alloc::allocClosure(&initEval, 0);
    effCl = alloc::allocClosure(&onEffectsEval, 4);
    selfCl = alloc::allocClosure(&onSelfMsgEval, 3);
    subMapCl = alloc::allocClosure(&subMapEval, 2);
    PlatformRuntime::ManagerInfo info{enc(initCl), enc(effCl), enc(selfCl),
                                      enc(alloc::listNil()), enc(subMapCl)};
    PlatformRuntime::instance().registerManager("System.File", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_System_File() {
    ECO_KERNEL_GUARD(
        registerFileManager();
        return enc(alloc::unit());
    )
}
