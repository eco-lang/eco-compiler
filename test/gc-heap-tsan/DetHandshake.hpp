// Register reproductions, Phase C (plans/threaded-gc-register-repros-impl.md
// §5): the ordering handshake of the deterministic TSan arms (det-cr014-live,
// det-cr001, det-cr002, det-cr019, cr012). RELAXED atomics only: TSan derives
// no happens-before edge from a relaxed store/load pair, so ordering two
// threads with these leaves every unsynchronised access pair visible to it.
// Workers never print, assert or take a std::mutex (each would add an edge).
#pragma once
#include <atomic>
#include <thread>

namespace det {
inline void waitFor(std::atomic<int>& s, int v) {
    while (s.load(std::memory_order_relaxed) < v) std::this_thread::yield();
}
inline void post(std::atomic<int>& s, int v) { s.store(v, std::memory_order_relaxed); }
// Exit codes of the deterministic arms (TSan turns a run with a report into 66).
constexpr int kClean = 0;
constexpr int kNotReached = 3;
}  // namespace det
