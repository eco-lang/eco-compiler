// File watch unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/FileSystem/WatchService.cpp).
//
// The WATCH-* guards drive Fs::WatchService (system-kernel-cpp/src/eco-system/FileSystem/WatchService.cpp)
// directly: add / drain / hasEvents. In inotify mode records are turned into events only in `drain`, so the
// test decides exactly when the watches for new directories are added, which makes the cases deterministic.
// The service picks its mode once, at its first `instance()`, from ECO_SYSTEM_WATCH_POLL, so every case runs in
// a child scenario started with that variable set to "0" (inotify) or "1" (poll). A child prints
// `DEFECT=0|1 <what it saw>` and exits 0; a non-zero exit means its precondition failed (the setup did not
// happen, or the watcher saw nothing at all), which the parent reports as a plain failure, never as "fixed".
//
//   WATCH-02  a renamed sub-directory kept its old relative path (inotify): `b/x` was reported as `a/x`.
//   WATCH-03  a sub-directory moved out of the watch was still reported (inotify): `sub/x`.
//   WATCH-04  poll mode did not follow a watched symbolic link to a directory (lstat of the root): no event.
//   WATCH-05  poll mode reported the whole tree again when the vanished root reappeared (D29: it must go silent).
//   WATCH-07  an IN_Q_OVERFLOW record (wd -1) was dropped before its check; D29: one path-less Moved per watch.
//   WATCH-08  entries of a new sub-tree created before its watch was added were not reported (inotify).
// All six are fixed; each scenario is now a plain check (`DEFECT=0` expected).
//
// WATCH-02/03/08 also have E2E tests (test/eco-system/src/FileWatchRenameDirTest.elm, FileWatchMoveOutTest.elm,
// FileWatchNewTreeTest.elm); these are their deterministic twins.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/FileSystem/WatchService.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

namespace {

namespace fs = std::filesystem;
using Eco::System::Fs::WatchEvent;
using Eco::System::Fs::WatchService;

// --- Helpers used inside the child scenarios ---------------------------------------------------------------

// A fresh directory under /tmp (mkdtemp); empty string on failure.
std::string makeTempDir() {
    char tmpl[] = "/tmp/eco-watch-g11-XXXXXX";
    const char* d = ::mkdtemp(tmpl);
    return d ? std::string(d) : std::string();
}

void writeFile(const std::string& p, const char* text) {
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    f << text;
}

void sleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// Waits up to `waitMs` for a queued record, lets the burst settle for `settleMs`, and drains once. Returns
// the events of watch `id` (all watches when `id` is 0).
std::vector<WatchEvent> waitDrain(int64_t id, int waitMs, int settleMs = 100) {
    auto& w = WatchService::instance();
    auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(waitMs);
    while (!w.hasEvents() && std::chrono::steady_clock::now() < until) sleepMs(5);
    sleepMs(settleMs);
    std::vector<WatchEvent> all, mine;
    w.drain(all);
    for (auto& e : all)
        if (id == 0 || e.watchId == id) mine.push_back(e);
    return mine;
}

// Drains after a fixed wait (poll mode, whose thread runs once a second).
std::vector<WatchEvent> drainAfter(int64_t id, int ms) {
    sleepMs(ms);
    std::vector<WatchEvent> all, mine;
    WatchService::instance().drain(all);
    for (auto& e : all)
        if (e.watchId == id) mine.push_back(e);
    return mine;
}

std::string show(const std::vector<WatchEvent>& evs) {
    std::string s = "[";
    for (size_t i = 0; i < evs.size(); ++i) {
        if (i) s += ", ";
        s += evs[i].kind == 1 ? "moved " : "changed ";
        s += evs[i].hasPath ? evs[i].path : std::string("-");
    }
    return s + "]";
}

bool hasPath(const std::vector<WatchEvent>& evs, const std::string& p) {
    return std::any_of(evs.begin(), evs.end(), [&](const WatchEvent& e) { return e.hasPath && e.path == p; });
}

bool hasPathContaining(const std::vector<WatchEvent>& evs, const std::string& p) {
    return std::any_of(evs.begin(), evs.end(),
                       [&](const WatchEvent& e) { return e.hasPath && e.path.find(p) != std::string::npos; });
}

// Prints the verdict line the parent parses, and returns the child's exit status 0.
int verdict(bool defect, const std::string& how) {
    std::printf("DEFECT=%d %s\n", defect ? 1 : 0, how.c_str());
    std::fflush(stdout);
    return 0;
}

// Precondition failure: exit status 3 and a message on stderr.
int precondition(const std::string& what) {
    std::fprintf(stderr, "precondition failed: %s\n", what.c_str());
    std::fflush(stderr);
    return 3;
}

// --- Parent side ---------------------------------------------------------------------------------------------

const std::vector<std::pair<std::string, std::string>> kInotify = {{"ECO_SYSTEM_WATCH_POLL", "0"}};
const std::vector<std::pair<std::string, std::string>> kPoll = {{"ECO_SYSTEM_WATCH_POLL", "1"}};

// Runs scenario `name` as a plain check: the child must exit 0 with `DEFECT=0`.
void runPlain(const std::string& name, const std::vector<std::pair<std::string, std::string>>& env,
              int timeoutMs = 30000) {
    std::printf("cross-check %s\n", name.c_str());
    auto r = ChildScenario::runChildScenario(name, env, timeoutMs);
    CHECK_MSG(r.ok() && r.out.find("DEFECT=0") != std::string::npos,
              name + ": " + r.describe() + "; stdout: " + r.out + "; stderr: " + r.err);
}

// --- WATCH-02: renamed sub-directory keeps its stale relative path (inotify) ---------------------------------
int scenarioRenameDir() {
    initCoreRuntime();
    const std::string d = makeTempDir();
    if (d.empty()) return precondition("mkdtemp");
    auto& w = WatchService::instance();
    const int64_t id = w.add(d, true);
    if (id <= 0) return precondition("add returned " + std::to_string(id));
    fs::create_directory(d + "/a");
    auto e1 = waitDrain(id, 2000);   // maps IN_CREATE a and adds the watch on a
    if (!hasPath(e1, "a")) return precondition("no event for a: " + show(e1));
    fs::rename(d + "/a", d + "/b");
    auto e2 = waitDrain(id, 2000);   // MOVED_FROM a, MOVED_TO b
    writeFile(d + "/b/x", "x");
    auto e3 = waitDrain(id, 2000);
    fs::remove_all(d);
    if (!hasPathContaining(e3, "x")) return precondition("no event for the file x: " + show(e3));
    const bool defect = hasPath(e3, "a/x") || !hasPath(e3, "b/x");
    return verdict(defect, "after rename " + show(e2) + "; file events " + show(e3) + " (expected b/x)");
}

// --- WATCH-03: a sub-directory moved out keeps being reported (inotify) ---------------------------------------
int scenarioMoveOut() {
    initCoreRuntime();
    const std::string r = makeTempDir();
    const std::string o = makeTempDir();
    if (r.empty() || o.empty()) return precondition("mkdtemp");
    auto& w = WatchService::instance();
    const int64_t id = w.add(r, true);
    if (id <= 0) return precondition("add returned " + std::to_string(id));
    fs::create_directory(r + "/sub");
    auto e1 = waitDrain(id, 2000);   // adds the watch on sub
    if (!hasPath(e1, "sub")) return precondition("no event for sub: " + show(e1));
    fs::rename(r + "/sub", o + "/gone");
    auto e2 = waitDrain(id, 2000);
    writeFile(o + "/gone/x", "x");
    sleepMs(300);
    writeFile(r + "/marker", "m");
    auto e3 = waitDrain(id, 2000, 200);
    fs::remove_all(r);
    fs::remove_all(o);
    if (!hasPath(e3, "marker")) return precondition("no event for marker: " + show(e3));
    const bool defect = hasPathContaining(e3, "/x");   // today: sub/x
    return verdict(defect, "after move-out " + show(e2) + "; then " + show(e3) + " (expected only marker)");
}

// --- WATCH-04: symbolic link as the watched root (both modes; poll is the defect) -----------------------------
int scenarioSymlinkRoot() {
    initCoreRuntime();
    const std::string t = makeTempDir();
    if (t.empty()) return precondition("mkdtemp");
    fs::create_directory(t + "/d");
    std::error_code ec;
    fs::create_directory_symlink(t + "/d", t + "/L", ec);
    if (ec) return precondition("symlink: " + ec.message());
    auto& w = WatchService::instance();
    const int64_t id = w.add(t + "/L", false);
    if (id <= 0) return precondition("add(L) returned " + std::to_string(id));
    sleepMs(100);
    writeFile(t + "/d/f", "f");
    // Poll runs once a second; collect for up to 3.5 s.
    std::vector<WatchEvent> evs;
    auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(3500);
    while (!hasPath(evs, "f") && std::chrono::steady_clock::now() < until) {
        auto more = waitDrain(id, 200, 0);
        evs.insert(evs.end(), more.begin(), more.end());
    }
    fs::remove_all(t);
    return verdict(!hasPath(evs, "f"), "events of the watch on L -> d after writing d/f: " + show(evs) +
                                           " (expected one for f)");
}

// --- WATCH-05: poll mode after the watched root vanishes and reappears ----------------------------------------
// Verdict: the drain after the root reappears must be empty (D29: the watch is finished after its path-less
// Moved). In poll mode the drain after the removal must also be exactly one path-less Moved (precondition).
int scenarioRootVanishes() {
    initCoreRuntime();
    const char* pm = std::getenv("ECO_SYSTEM_WATCH_POLL");
    const bool poll = pm && std::string(pm) == "1";
    const std::string t = makeTempDir();
    if (t.empty()) return precondition("mkdtemp");
    const std::string d = t + "/d";
    auto build = [&] {
        fs::create_directories(d + "/s");
        writeFile(d + "/a", "a");
        writeFile(d + "/s/b", "b");
    };
    build();
    auto& w = WatchService::instance();
    const int64_t id = w.add(d, true);
    if (id <= 0) return precondition("add returned " + std::to_string(id));
    auto e1 = drainAfter(id, 1500);
    fs::remove_all(d);
    auto e2 = drainAfter(id, 1500);
    const bool pathlessMoved = std::any_of(e2.begin(), e2.end(),
                                           [](const WatchEvent& e) { return e.kind == 1 && !e.hasPath; });
    if (!pathlessMoved) return precondition("no path-less Moved after removing the root: " + show(e2));
    if (poll && e2.size() != 1) return precondition("poll: expected exactly one event after removal: " + show(e2));
    build();
    auto e3 = drainAfter(id, 2500);
    fs::remove_all(t);
    return verdict(!e3.empty(), std::string(poll ? "poll" : "inotify") + ": before " + show(e1) + "; removal " +
                                    show(e2) + "; after re-creation " + show(e3) + " (expected none)");
}

// --- WATCH-07: IN_Q_OVERFLOW (wd -1) must yield one path-less Moved per watch (inotify) -----------------------
int scenarioQueueOverflow() {
    initCoreRuntime();
#if ECO_TEST_HOOKS
    const std::string d1 = makeTempDir();
    const std::string d2 = makeTempDir();
    if (d1.empty() || d2.empty()) return precondition("mkdtemp");
    auto& w = WatchService::instance();
    const int64_t id1 = w.add(d1, false);
    const int64_t id2 = w.add(d2, false);
    if (id1 <= 0 || id2 <= 0) return precondition("add failed");
    sleepMs(50);
    std::vector<WatchEvent> junk;
    w.drain(junk);
    w.injectQueueOverflowForTest();
    if (!w.hasEvents()) return precondition("the injected record is not queued");
    auto evs = waitDrain(0, 1000, 50);
    fs::remove_all(d1);
    fs::remove_all(d2);
    auto pathless = [&](int64_t id) {
        return std::any_of(evs.begin(), evs.end(),
                           [&](const WatchEvent& e) { return e.watchId == id && e.kind == 1 && !e.hasPath; });
    };
    return verdict(!(pathless(id1) && pathless(id2)),
                   "events after an injected overflow: " + show(evs) + " (expected a path-less Moved for each of "
                   "watches " + std::to_string(id1) + " and " + std::to_string(id2) + ")");
#else
    return precondition("ECO_TEST_HOOKS is 0 in this build: injectQueueOverflowForTest is not compiled");
#endif
}

// --- WATCH-08: a new sub-tree's entries created before its watches are added (inotify) ------------------------
int scenarioNewTree() {
    initCoreRuntime();
    const std::string d = makeTempDir();
    if (d.empty()) return precondition("mkdtemp");
    auto& w = WatchService::instance();
    const int64_t id = w.add(d, true);
    if (id <= 0) return precondition("add returned " + std::to_string(id));
    fs::create_directories(d + "/a/b/c");
    writeFile(d + "/a/b/c/f", "f");
    auto evs = waitDrain(id, 2000);
    auto more = waitDrain(id, 300);   // anything the watches added by the first drain produce
    evs.insert(evs.end(), more.begin(), more.end());
    fs::remove_all(d);
    if (!hasPath(evs, "a")) return precondition("no event for a: " + show(evs));
    const bool defect = !hasPath(evs, "a/b") || !hasPath(evs, "a/b/c") || !hasPath(evs, "a/b/c/f");
    return verdict(defect, "events " + show(evs) + " (expected a, a/b, a/b/c, a/b/c/f)");
}

void testWatchGuards() {
    runPlain("watch/rename-dir", kInotify);
    runPlain("watch/move-out", kInotify);
    // WATCH-04 and WATCH-05: both modes must agree.
    runPlain("watch/symlink-root", kInotify);
    runPlain("watch/symlink-root", kPoll);
    runPlain("watch/root-vanishes", kInotify);
    runPlain("watch/root-vanishes", kPoll);
    runPlain("watch/queue-overflow", kInotify);
    runPlain("watch/new-tree", kInotify);
}

}  // namespace

void runWatchTests() {
#if defined(__linux__)
    testWatchGuards();
#endif
}

void registerWatchScenarios() {
    ChildScenario::add("watch/rename-dir", scenarioRenameDir);
    ChildScenario::add("watch/move-out", scenarioMoveOut);
    ChildScenario::add("watch/symlink-root", scenarioSymlinkRoot);
    ChildScenario::add("watch/root-vanishes", scenarioRootVanishes);
    ChildScenario::add("watch/queue-overflow", scenarioQueueOverflow);
    ChildScenario::add("watch/new-tree", scenarioNewTree);
}
