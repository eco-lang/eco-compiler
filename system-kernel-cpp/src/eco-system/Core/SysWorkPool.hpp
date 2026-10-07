//===- SysWorkPool.hpp - Worker pool for short blocking syscalls ----------===//
//
// plans/eco-system-library.md §3.4 / T2. `min(4, hardware_concurrency)`
// detached worker threads run POD-only jobs (stat, open, readdir, ...) and
// queue their results; the main-thread pool drain (registered once through
// the eco/system async source) turns each result into a Task and resumes the
// parked binding.
//
// Threading (G1): `work` runs on a worker thread and must not touch the
// heap, call Elm, or log through Debug.log. `complete` runs on the main
// thread, with the resume already taken and rooted.
//
// Keep-alive: the binding body calls incrementPendingAsync() before submit;
// the drain decrements exactly once per result (AsyncRelease), and the T7
// kill handle decrements instead when `cancel(token)` removed a queued job.
//
// Templates used: T2, T7 (cancel).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_SYS_WORK_POOL_HPP
#define ECO_SYSTEM_CORE_SYS_WORK_POOL_HPP

#include "eco-system/Core/Core.hpp"

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <deque>
#include <functional>
#include <mutex>
#include <new>
#include <type_traits>
#include <utility>

namespace Eco::System {

// ---------------------------------------------------------------------------
// PoolResult: a type-erased, move-only holder for a POD-ish job result, with
// a small inline buffer (results up to kInline bytes are not heap-allocated
// separately). It must never hold an HPointer (G1): that is checked for the
// obvious cases at compile time.
// ---------------------------------------------------------------------------

class PoolResult {
public:
    PoolResult() = default;
    PoolResult(PoolResult&& o) noexcept { moveFrom(o); }
    PoolResult& operator=(PoolResult&& o) noexcept {
        if (this != &o) { reset(); moveFrom(o); }
        return *this;
    }
    PoolResult(const PoolResult&) = delete;
    PoolResult& operator=(const PoolResult&) = delete;
    ~PoolResult() { reset(); }

    template <typename T>
    static PoolResult of(T&& v) {
        using U = std::decay_t<T>;
        static_assert(!std::is_same_v<U, HPointer> && !std::is_same_v<U, Unboxable>,
                      "PoolResult must not hold heap references (G1)");
        static_assert(std::is_move_constructible_v<U>, "PoolResult needs a movable type");
        PoolResult r;
        if constexpr (fitsInline<U>()) {
            r.ptr_ = ::new (static_cast<void*>(r.buf_)) U(std::forward<T>(v));
            r.inline_ = true;
        } else {
            r.ptr_ = new U(std::forward<T>(v));
            r.inline_ = false;
        }
        r.vt_ = &vtableFor<U>;
        return r;
    }

    bool empty() const { return vt_ == nullptr; }

    template <typename T>
    bool holds() const { return vt_ == &vtableFor<T>; }

    // The held value. Aborts on a type mismatch (a programming error).
    template <typename T>
    T& as() {
        if (!holds<T>()) {
            std::fprintf(stderr, "[eco-system] FATAL: PoolResult::as<T>() type mismatch\n");
            std::fflush(stderr);
            std::abort();
        }
        return *static_cast<T*>(ptr_);
    }

    void reset() {
        if (vt_) {
            if (inline_) vt_->destroyInline(ptr_);
            else vt_->destroyHeap(ptr_);
        }
        vt_ = nullptr;
        ptr_ = nullptr;
        inline_ = false;
    }

private:
    static constexpr size_t kInline = 64;

    struct VTable {
        void (*destroyInline)(void*);
        void (*destroyHeap)(void*);
        void* (*moveInline)(void* dst, void* src);   // move-construct src into dst
    };

    template <typename U>
    static constexpr bool fitsInline() {
        return sizeof(U) <= kInline && alignof(U) <= alignof(std::max_align_t) &&
               std::is_nothrow_move_constructible_v<U>;
    }

    template <typename U>
    static void destroyInlineImpl(void* p) { static_cast<U*>(p)->~U(); }
    template <typename U>
    static void destroyHeapImpl(void* p) { delete static_cast<U*>(p); }
    template <typename U>
    static void* moveInlineImpl(void* dst, void* src) {
        if constexpr (fitsInline<U>()) {
            U* s = static_cast<U*>(src);
            U* d = ::new (dst) U(std::move(*s));
            s->~U();
            return d;
        } else {
            (void)dst; (void)src;
            return nullptr;   // never inline
        }
    }

    template <typename U>
    static inline const VTable vtableFor{&destroyInlineImpl<U>, &destroyHeapImpl<U>,
                                         &moveInlineImpl<U>};

    void moveFrom(PoolResult& o) noexcept {
        vt_ = o.vt_;
        inline_ = o.inline_;
        if (!vt_) { ptr_ = nullptr; return; }
        if (inline_) ptr_ = vt_->moveInline(buf_, o.ptr_);   // destroys o's copy
        else ptr_ = o.ptr_;
        o.vt_ = nullptr;
        o.ptr_ = nullptr;
        o.inline_ = false;
    }

    alignas(std::max_align_t) unsigned char buf_[kInline];
    void* ptr_ = nullptr;
    const VTable* vt_ = nullptr;
    bool inline_ = false;
};

// Main thread: turns a result into the Task handed to the resume. May
// allocate; the drain roots the returned Task.
using CompleteFn = HPointer (*)(PoolResult&);

// What a worker thread produces when `work` throws: the drain then fails the
// task with the job's error shape.
struct PoolException {
    std::string what;
};

class SysWorkPool {
public:
    static SysWorkPool& instance();

    // Main thread. The caller has registered `token` (registerPendingResume)
    // and called incrementPendingAsync() (G10). `shape` picks the failure if
    // `work` or `complete` throws (B2).
    void submit(uint64_t token, std::function<PoolResult()> work,
                CompleteFn complete, ErrShape shape = ErrShape::FErr);

    // T7 CancelFn: removes a job that has not started yet. Returns true iff
    // it removed one (the caller — the kill handle — then decrements).
    static bool cancel(uint64_t token);

    // One finished job.
    struct Item {
        uint64_t token = 0;
        PoolResult result;
        CompleteFn complete = nullptr;
        ErrShape shape = ErrShape::FErr;
    };

    // Main thread (the drain, or a test). Non-blocking.
    bool tryPop(Item& out);
    bool hasReady() const { return readyCount_.load(std::memory_order_acquire) > 0; }

    size_t threadCount() const { return nThreads_; }

private:
    SysWorkPool();
    ~SysWorkPool() = default;

    void workerLoop();

    struct Job {
        uint64_t token;
        std::function<PoolResult()> work;
        CompleteFn complete;
        ErrShape shape;
    };

    std::mutex jobsMutex_;
    std::condition_variable jobsCV_;
    std::deque<Job> jobs_;

    std::mutex readyMutex_;
    std::deque<Item> ready_;
    std::atomic<size_t> readyCount_{0};

    Scheduler* sched_ = nullptr;
    size_t nThreads_ = 0;
};

// The T2 pool drain (main thread). Runs from the eco/system async source;
// tests may call it directly. For each result: pop; take the resume (nil →
// the task was killed: decrement and continue); root; task = complete(pr);
// root; resume; decrement (AsyncRelease). After the loop, drain() once.
void poolDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_SYS_WORK_POOL_HPP
