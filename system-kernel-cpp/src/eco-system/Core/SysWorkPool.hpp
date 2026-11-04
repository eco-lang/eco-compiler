//===- SysWorkPool.hpp - Worker pool for short blocking syscalls ----------===//
//
// eco/system kernels need calls such as stat, open and readdir that may block, and the eco thread, which runs
// all Elm code, must not wait on them. This component runs such calls on a small pool of worker threads and
// turns each result back into a Task on the eco thread.
//
// One rule shapes everything here: a worker thread must never touch the GC heap. A job is therefore split in
// two. Its `work` runs on a worker and produces a plain C++ value, held in a `PoolResult`. Its `complete`
// runs later on the eco thread and builds the Task from that value. In between, the result waits in a queue
// guarded by a mutex until `poolDrain`, the pool's drain source in the eco/system async source
// (`addDrainSource`), pops it.
//
// A job is tied to a task by a resume token. Before `submit`, the caller parks the task's resume closure and
// acquires the hold keyed by its token, as `Scheduler::parkResume` does. For each result, `poolDrain`
// releases that hold exactly once. If the task was killed first, its kill handle has already taken the
// resume, and the drain releases the hold without resuming anything. When `cancel` removes a job that has
// not started, no result will ever arrive, and the kill handle releases the hold instead.
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

/// The result of one pool job: a value of any movable type, or nothing, owned by this object.
///
/// It exists so that jobs with different result types share one queue. The value must not refer to the GC
/// heap. `of` refuses an `HPointer` or `Unboxable` at compile time, but cannot see one inside another type,
/// so a result type must not contain one. A value of at most 64 bytes, alignment at most
/// `alignof(std::max_align_t)` and a non-throwing move constructor is stored inside the object, and any other
/// value in a separate C++ heap allocation.
///
/// A `PoolResult` can be moved but not copied. Moving hands the value over, and the moved-from object is
/// empty. Destroying or resetting it destroys the value.
class PoolResult {
public:
    /// Creates an empty result.
    PoolResult() = default;
    PoolResult(PoolResult&& o) noexcept { moveFrom(o); }
    PoolResult& operator=(PoolResult&& o) noexcept {
        if (this != &o) { reset(); moveFrom(o); }
        return *this;
    }
    PoolResult(const PoolResult&) = delete;
    PoolResult& operator=(const PoolResult&) = delete;
    ~PoolResult() { reset(); }

    /// Returns a result holding `v`, moved or copied in, as a `std::decay_t<T>`. Throws whatever that
    /// type's constructor throws, and `std::bad_alloc` when a value too large to hold inline cannot be
    /// allocated.
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

    /// Returns whether the result holds no value.
    bool empty() const { return vt_ == nullptr; }

    /// Returns whether the result holds a value whose type is exactly `T`, the decayed type `of` was
    /// called with. A cv-qualified or reference `T` never matches.
    template <typename T>
    bool holds() const { return vt_ == &vtableFor<T>; }

    /// Returns the held value, which must be of type `T` as `holds` decides. On a mismatch, including an
    /// empty result, it prints a message to stderr and aborts the process. The reference is valid until
    /// the result is reset, assigned to, moved from or destroyed.
    template <typename T>
    T& as() {
        if (!holds<T>()) {
            std::fprintf(stderr, "[eco-system] FATAL: PoolResult::as<T>() type mismatch\n");
            std::fflush(stderr);
            std::abort();
        }
        return *static_cast<T*>(ptr_);
    }

    /// Destroys the held value, if any, leaving the result empty.
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
    /// The size in bytes of the inline buffer, the largest value held without a separate allocation.
    static constexpr size_t kInline = 64;

    /// The operations on one held type: destroying it inline or on the C++ heap, and moving an inline
    /// value. There is one table per type, and its address identifies the type for `holds`.
    struct VTable {
        void (*destroyInline)(void*);
        void (*destroyHeap)(void*);
        void* (*moveInline)(void* dst, void* src);   // move src into dst, destroy src, return dst
    };

    /// Returns whether a value of type `U` is held inline: small enough for the buffer, aligned no more
    /// strictly than it, and with a move constructor that cannot throw, so that moving a result cannot fail.
    template <typename U>
    static constexpr bool fitsInline() {
        return sizeof(U) <= kInline && alignof(U) <= alignof(std::max_align_t) &&
               std::is_nothrow_move_constructible_v<U>;
    }

    /// Destroys the inline `U` at `p` without freeing its storage.
    template <typename U>
    static void destroyInlineImpl(void* p) { static_cast<U*>(p)->~U(); }
    /// Destroys and frees the `U` at `p`, which `of` allocated with `new`.
    template <typename U>
    static void destroyHeapImpl(void* p) { delete static_cast<U*>(p); }
    /// Move-constructs the inline `U` at `src` into the storage at `dst`, destroys the one at `src`, and
    /// returns the new object's address. For a type that is never held inline it does nothing and returns
    /// null; `moveFrom` never calls it for such a type.
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

    /// The operation table for type `U`.
    template <typename U>
    static inline const VTable vtableFor{&destroyInlineImpl<U>, &destroyHeapImpl<U>,
                                         &moveInlineImpl<U>};

    /// Takes the value of `o`, which must not be this object, into this empty object, leaving `o` empty.
    /// An inline value is moved into this object's buffer; a heap value's pointer is taken over.
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
    void* ptr_ = nullptr;          ///< The held value, in `buf_` or on the C++ heap; null when empty.
    const VTable* vt_ = nullptr;   ///< The held type's operations; null exactly when empty.
    bool inline_ = false;          ///< Whether the value is in `buf_` rather than separately allocated.
};

/// A job's completion: builds, on the eco thread, the Task that the job's result resumes its task with.
///
/// It may allocate on the GC heap. It may throw; `poolDrain` then uses the job's failure shape instead.
using CompleteFn = HPointer (*)(PoolResult&);

/// A job's hand-off: called on the eco thread with the job's token and result (a `PoolException` if `work` threw),
/// before `poolDrain` looks at the task's resume. It returns true when it took the token over, having started further
/// work under the same token: that work now owns the parked resume and the hold, so the drain neither resumes the task
/// nor releases the hold. It returns false to have the drain finish the job as usual (resume with `complete`, or
/// release only if the task was killed). It must tell a killed task apart itself, from its own record of the kill
/// handle's cancel, since the drain has not yet taken the resume. If it throws, it took nothing over, and the task
/// fails with the job's failure shape.
using HandoffFn = bool (*)(uint64_t token, PoolResult&);

/// The result a worker stores in place of the job's own when `work` throws, carrying the exception's
/// message, or a fixed message for an exception not derived from `std::exception`. The message is empty when
/// the worker could not allocate a copy of it.
///
/// `poolDrain` fails the task with the job's failure shape and this message (for an empty one, "out of memory
/// in kernel"), without calling `complete`.
struct PoolException {
    std::string what;
};

/// The process's pool of worker threads for short blocking calls, and the queues of jobs and results
/// between them and the eco thread.
///
/// There is one pool, obtained through `instance`. Once `instance` has returned it, it is never destroyed,
/// and its workers are detached threads that run for the life of the process, so exiting the process never
/// destroys the pool under a running worker.
///
/// Jobs are started in the order they were submitted, by whichever worker is free, so several may run at
/// once and finish in any order. Results are queued in the order they finish.
class SysWorkPool {
public:
    /// Returns the pool, creating it and starting its workers on the first call. The first call must be
    /// made on the eco thread, since creating the pool binds `Scheduler::instance()`. If some but not all
    /// worker threads can be started, the pool runs with those that started and says so once on stderr. If
    /// none can be started, the call throws `std::system_error`, and the next call tries again.
    static SysWorkPool& instance();

    /// Queues a job for `token`, a resume token whose resume the caller has parked and whose hold it has
    /// acquired, as `Scheduler::parkResume` does. Must be called on the eco thread.
    ///
    /// A worker runs `work`, which must not touch the GC heap or call Elm, and is destroyed on that worker
    /// once it returns. Unless the task was killed, `poolDrain` then passes its result to `complete`, on
    /// the eco thread, and resumes the task with the Task `complete` returns. If `work` or `complete` throws,
    /// the task is resumed with `detail::failureFor(shape, message)` instead; for `ErrShape::Never` that ends
    /// the process. The first call also adds `poolDrain` to the eco/system async source.
    void submit(uint64_t token, std::function<PoolResult()> work,
                CompleteFn complete, ErrShape shape = ErrShape::FErr);
    /// Queues a job as the other overload does, whose result is first offered to `handoff` (see `HandoffFn`), so that
    /// a two-step operation can start its second step under the same token, with no Task in between to be killed.
    void submit(uint64_t token, std::function<PoolResult()> work,
                CompleteFn complete, ErrShape shape, HandoffFn handoff);

    /// Removes the job for `token` if no worker has started it, and returns whether it removed one. A job
    /// that is running or finished is left alone. Suited to be the `CancelFn` given to `makeKillHandle`:
    /// on true, the caller must release the token's hold, since no result will arrive to release it.
    /// The removed `work` is destroyed on the calling thread.
    ///
    /// The search through the queued jobs is linear.
    static bool cancel(uint64_t token);

    /// One finished job, as it waits for `poolDrain`.
    struct Item {
        uint64_t token = 0;
        /// What `work` returned, or a `PoolException` if it threw.
        PoolResult result;
        CompleteFn complete = nullptr;
        /// The failure shape for a `PoolException` result or a throwing `complete`.
        ErrShape shape = ErrShape::FErr;
        /// The job's hand-off, or null for none.
        HandoffFn handoff = nullptr;
    };

    /// Moves the oldest finished job into `out` and returns true, or returns false, leaving `out`
    /// unchanged, when none is waiting. Does not block. Called on the eco thread, by `poolDrain`.
    bool tryPop(Item& out);
    /// Returns whether a finished job is waiting. May be called from any thread; it takes no lock.
    bool hasReady() const { return readyCount_.load(std::memory_order_acquire) > 0; }

    /// Returns the number of worker threads: the smaller of 4 and `std::thread::hardware_concurrency()`,
    /// or 1 when that reports 0, less any that could not be started (never below 1).
    size_t threadCount() const { return nThreads_; }

#if ECO_TEST_HOOKS
    /// Test-only (FS-03): makes the next `submit` throw `std::bad_alloc` before it queues anything. The fault
    /// fires once and then disarms itself. Any thread may arm it.
    static void failNextSubmitForTest();

    /// A function that starts one worker thread running `body`, detached. It reports a failure by throwing,
    /// as `std::thread`'s constructor does (`std::system_error`).
    using StartWorkerFn = void (*)(std::function<void()> body);
    /// Test-only (CORE-01): replaces the function the constructor starts each worker with, and returns the
    /// previous one; null restores the default, `std::thread(body).detach()`. It takes effect only if set
    /// before the first `instance()` call of the process, so a test sets it in a fresh process.
    static StartWorkerFn setWorkerStarterForTest(StartWorkerFn fn);
#endif

private:
    /// Binds the Scheduler and starts the detached worker threads.
    SysWorkPool();
    ~SysWorkPool() = default;

    /// Runs one worker for ever: takes the oldest queued job, waiting while there is none, runs it, queues
    /// its result and wakes the Scheduler. It never lets an exception escape; if the result cannot be queued
    /// for lack of memory, it ends the process with `Eco::Kernel::reportFatal`.
    void workerLoop();

    /// One job waiting for a worker.
    struct Job {
        uint64_t token;
        std::function<PoolResult()> work;
        CompleteFn complete;
        ErrShape shape;
        HandoffFn handoff = nullptr;
    };

    // Jobs not yet started, guarded by `jobsMutex_`. Workers wait on `jobsCV_` while the queue is empty.
    std::mutex jobsMutex_;
    std::condition_variable jobsCV_;
    std::deque<Job> jobs_;

    // Finished jobs, guarded by `readyMutex_`. `readyCount_` is the number of them, kept so that `hasReady`
    // need not take the lock.
    std::mutex readyMutex_;
    std::deque<Item> ready_;
    std::atomic<size_t> readyCount_{0};

    /// The process's Scheduler, bound by the constructor so that workers never call `Scheduler::instance()`.
    /// Never null after construction.
    Scheduler* sched_ = nullptr;
    size_t nThreads_ = 0;
};

/// Delivers every finished pool job to its task, on the eco thread. It is the pool's drain in the eco/system
/// async source, and may also be called directly.
///
/// For each finished job with a hand-off, it first offers the result to it, and moves on if the hand-off took the token
/// over. For each other finished job, it takes the resume parked under the job's token. If there is none, because the
/// task was killed, the job's result is dropped. Otherwise it resumes the task with the Task `complete`
/// builds, or with the job's failure shape if `work` or `complete` threw (for `ErrShape::Never`, ending the
/// process). Either way it then releases the token's hold, once. If it resumed any task and no exception
/// escaped a resume, it runs the Scheduler's queue once at the end, with `Scheduler::drain`.
void poolDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_SYS_WORK_POOL_HPP
