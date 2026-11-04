//===- FileSystemManager.cpp - The C++ effect manager of `FileSystem` ----===//
//
// The manager's state is one entry in a `Registry`, so the collector updates
// the encoded router and taggers it holds. It maps each (path, recursive) key
// to its watch id, its liveness hold and the taggers of its subscriptions.
//
// A collection may move any heap object, so a pointer obtained by resolving a
// word is used only until the next allocation or Elm call. The closures below
// that resolve heap objects copy the words they need out of the heap first,
// root them, and only then allocate or call Elm.
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

// The identity of a watch: the watched path, and whether it is recursive.
using WatchKey = std::pair<std::string, bool>;

// The watch of one key and the subscriptions that share it.
struct WatchEntry {
    int64_t watchId = 0;    // 0 when the path could not be watched, or after stopWatch
    HoldToken hold = kNoHold;   // held only while watchId is not 0
    std::vector<uint64_t> taggers;   // encoded taggers, in subscription order
};

// Everything the manager keeps between calls.
struct ManagerState {
    uint64_t routerEnc = 0;   // 0 until the first onEffects
    std::map<WatchKey, WatchEntry> watches;

    // Calls `f` on every encoded heap word the state holds, for the Registry's
    // root scanner.
    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& kv : watches)
            for (auto& w : kv.second.taggers) f(w);
    }
};

// Returns the registry that holds the manager's state. It is never destroyed.
Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-file-manager");   // leaky
    return *r;
}

// Returns the manager's one state entry, creating an empty one on the first
// call and again after a heap reset has cleared the registry. The reference is
// valid until the registry is next cleared.
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

// --- Delivery ----------------------------------------------------------------

// Sends `ev` to the program once for every tagger of its watch, draining the
// scheduler after each message. Does nothing before the first onEffects, or
// when no current key has the event's watch id, as for an event queued before
// its watch was stopped.
//
// The taggers are copied and rooted first, because the Elm calls and drains
// may run onEffects, which can replace or erase the entry.
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
    // Nothing has allocated since the decodes above, so the words are current.
    Elm::StackRootGuard g({&router, &str, &arg, &msg});
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(taggers.data(), taggers.size(), ~0ULL);
    for (size_t i = 0; i < taggers.size(); ++i) {
        if (ev.hasPath) {
            str = alloc::allocStringFromUTF8(ev.path);
            // `just` allocates while its argument is rooted (`str`); its fresh
            // result goes straight into tuple2, which roots it.
            arg = alloc::tuple2(alloc::unboxedInt(ev.kind),
                                alloc::boxed(alloc::just(alloc::boxed(str), true)), 0x1);
        } else {
            arg = alloc::tuple2(alloc::unboxedInt(ev.kind), alloc::boxed(alloc::nothing()), 0x1);
        }
        msg = Scheduler::callClosure1(taggers[i], arg);
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();
    }
    rs.restoreStackRangePoint(saved);
}

// Delivers every queued watch event. An exception from a delivery ends the
// process with a fatal error rather than unwinding into the scheduler loop.
void watchDrain() {
    std::vector<WatchEvent> evs;
    WatchService::instance().drain(evs);
    for (auto& ev : evs) {
        try {
            deliver(ev);
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in FileSystem watch delivery");
        }
    }
}

// Returns whether the watch service has queued records. Any thread may call it.
bool watchReady() {
    return WatchService::instance().hasEvents();
}

// --- Manager closures ----------------------------------------------------------

// Evaluates `init : Task Never ()`, returning a Task that succeeds with `()`.
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// Stops the watch of `e`, if it has one, and releases its hold.
void stopWatch(WatchEntry& e) {
    if (e.watchId != 0) WatchService::instance().remove(e.watchId);
    if (e.hold != kNoHold) Scheduler::instance().releaseHold(e.hold);
    e.watchId = 0;
    e.hold = kNoHold;
}

// Evaluates `onEffects router cmds subs state`, making the watches match
// `subs`: a key no subscription names any more is stopped, a new key starts a
// watch and, if the path could be watched, takes a Subscription hold, and every
// remaining key gets the taggers of its current subscriptions. Returns a Task
// that succeeds with `()`.
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &subs);

    // Nothing in this walk allocates, so the resolved objects stay put.
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
        ::Eco::Kernel::reportFatal("eco/system: FileSystem.watch is not supported on Windows yet");
#endif

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
                    e.hold = Scheduler::instance().acquireHold(
                        HoldKind::Subscription, "FileSystem.watch");
                }
                it = st.watches.emplace(kv.first, std::move(e)).first;
            }
            it->second.taggers = std::move(kv.second);
        }
    }

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// Evaluates `onSelfMsg router msg state`, returning a Task that succeeds with
// `state`. The manager sends itself no messages.
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// Evaluates the tagger subMap builds, with captures `f` and `old` followed by
// the event tuple, and returns `f (old event)`.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer old = dec(args[1]);
    HPointer event = dec(args[2]);
    HPointer mid = alloc::listNil();
    Elm::StackRootGuard g({&f, &old, &event, &mid});
    mid = Scheduler::callClosure1(old, event);
    HPointer out = Scheduler::callClosure1(f, mid);
    return reinterpret_cast<void*>(enc(out));
}

// Evaluates `subMap f sub`, returning a `Watch` with the same path and flag
// whose tagger applies `f` after the old one. A value that is not a `Watch` is
// returned unchanged.
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
        // Both captures go in before anything else allocates.
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

// Allocates the manager closures and registers them under "FileSystem". The
// manager has no commands, so its cmdMap is the empty list.
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
    PlatformRuntime::instance().registerManager("FileSystem", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_FileSystem() {
    ECO_KERNEL_GUARD(
        registerFileManager();
        return enc(alloc::unit());
    )
}
