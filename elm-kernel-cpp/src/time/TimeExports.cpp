//===- TimeExports.cpp - C-linkage exports for Time module -----------------===//
//
// Full implementation of elm/time kernel functions.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "platform/Scheduler.hpp"
#include "platform/TaskBinding.hpp"
#include <chrono>
#include <ctime>
#include <cstdlib>
#include <cstring>
#include <string>

#if defined(__linux__) || defined(__APPLE__)
#include <unistd.h>
#endif

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;
using namespace Elm::Platform;

namespace {

// Zone is represented as an Int (minutes offset from UTC)
// The Elm Time.Zone type is actually:
//   type Zone = Zone Int (List Era)
// where Era = { start : Int, offset : Int }
// For simplicity, we represent Zone as just the offset in minutes
// wrapped in a Custom type with ctor 0

// ZoneName is:
//   type ZoneName = Name String | Offset Int
// Name has ctor 0, Offset has ctor 1

// Sub ctor for Time.Every subscription
static constexpr u16 CTOR_TIME_EVERY = 0;

// Create a Zone value (offset in minutes from UTC)
// Zone = Custom { ctor: 0, values: [offsetMinutes (unboxed Int), eras (boxed List)] }
HPointer createZone(int offsetMinutes) {
    // Simplified Zone: just store offset, empty eras list
    std::vector<Unboxable> values(2);
    values[0].i = static_cast<i64>(offsetMinutes);
    values[1].p = listNil();  // empty eras list

    // Field 0 is unboxed (Int), field 1 is boxed (List)
    return custom(0, values, 0b01);
}

// Create a ZoneName.Name value
HPointer createZoneNameString(const std::string& name) {
    HPointer nameStr = allocStringFromUTF8(name);
    std::vector<Unboxable> values(1);
    values[0].p = nameStr;
    return custom(0, values, 0);  // ctor 0 = Name, field is boxed
}

// Create a ZoneName.Offset value
HPointer createZoneNameOffset(int offsetMinutes) {
    std::vector<Unboxable> values(1);
    values[0].i = static_cast<i64>(offsetMinutes);
    return custom(1, values, 1);  // ctor 1 = Offset, field is unboxed
}

// Get local timezone offset in minutes from UTC
int getLocalTimezoneOffset() {
#if defined(__linux__) || defined(__APPLE__)
    time_t now = time(nullptr);
    struct tm local_tm;
    localtime_r(&now, &local_tm);

    // tm_gmtoff is seconds east of UTC
    return static_cast<int>(local_tm.tm_gmtoff / 60);
#else
    // Windows fallback - use _timezone
    // _timezone is seconds west of UTC
    return -(_timezone / 60);
#endif
}

// Try to get the IANA timezone name
std::string getTimezoneName() {
#if defined(__linux__)
    // Try TZ environment variable first
    const char* tz = std::getenv("TZ");
    if (tz && tz[0] != '\0') {
        // TZ might be ":America/New_York" or "America/New_York"
        if (tz[0] == ':') {
            return std::string(tz + 1);
        }
        return std::string(tz);
    }

    // Try reading /etc/localtime symlink
    char buf[256];
    ssize_t len = readlink("/etc/localtime", buf, sizeof(buf) - 1);
    if (len > 0) {
        buf[len] = '\0';
        // Path is typically /usr/share/zoneinfo/America/New_York
        // We want to extract "America/New_York"
        const char* zoneinfo = "zoneinfo/";
        const char* found = strstr(buf, zoneinfo);
        if (found) {
            return std::string(found + strlen(zoneinfo));
        }
    }

    // Try /etc/timezone file
    FILE* f = fopen("/etc/timezone", "r");
    if (f) {
        char line[256];
        if (fgets(line, sizeof(line), f)) {
            fclose(f);
            // Remove trailing newline
            size_t l = strlen(line);
            if (l > 0 && line[l-1] == '\n') line[l-1] = '\0';
            return std::string(line);
        }
        fclose(f);
    }
#elif defined(__APPLE__)
    // Try TZ first
    const char* tz = std::getenv("TZ");
    if (tz && tz[0] != '\0') {
        if (tz[0] == ':') {
            return std::string(tz + 1);
        }
        return std::string(tz);
    }

    // Read /etc/localtime symlink
    char buf[256];
    ssize_t len = readlink("/etc/localtime", buf, sizeof(buf) - 1);
    if (len > 0) {
        buf[len] = '\0';
        const char* zoneinfo = "zoneinfo/";
        const char* found = strstr(buf, zoneinfo);
        if (found) {
            return std::string(found + strlen(zoneinfo));
        }
    }
#elif defined(_WIN32)
    // Try TZ first — same convention as POSIX, set by the Eco runtime tests.
    const char* tz = std::getenv("TZ");
    if (tz && tz[0] != '\0') {
        if (tz[0] == ':') return std::string(tz + 1);
        return std::string(tz);
    }
    // GetDynamicTimeZoneInformation returns the Windows-named time zone
    // (e.g. "Pacific Standard Time"). We do not translate that to an IANA
    // name here — the caller will fall back to the offset-only path, which
    // matches the empty-return branch on the POSIX side. A full ICU-based
    // mapping is plan W2 item 11b's "minimal in v1" position.
#endif

    // Fallback: return empty string to indicate we should use offset
    return "";
}

// Binding evaluator for Time.now: invoked when the scheduler consumes the
// Task_Binding. Reads system_clock at consumption time (not at module init)
// so successive Time.now references see distinct timestamps. Mirrors the JS
// kernel's `_Scheduler_binding(callback => callback(_Scheduler_succeed(...)))`.
//
// Arguments:
//   rawArgs[0] = millisToPosix closure (captured by the binding) — the
//                Elm `Posix` constructor wrapped as `Int -> Posix`.
//   rawArgs[1] = resume closure (applied by the scheduler).
//
// We cannot return a bare Int here because `Time.now : Task x Posix` —
// downstream pattern matches like `posixToMillis (Posix m) = m` read field 0
// of a Tag_Custom and a raw Tag_Int has the wrong layout (values[0] is at
// offset 16 on a Custom, but past the end of an ElmInt). Applying
// millisToPosix builds the Tag_Custom with the right ctor.
static void* timeNowBindingEvaluator(void* rawArgs[]) {
    uint64_t mtpEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer mtpHP = Export::decode(mtpEnc);
    HPointer resumeHP = Export::decode(resumeEnc);

    auto now = std::chrono::system_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()
    ).count();

    // Two allocations follow (eco_closure_call_saturated for the Posix
    // ctor, taskSucceed). Root mtpHP / resumeHP across both; root the
    // intermediate Posix and Task as they appear.
    HPointer posixHP = Elm::alloc::listNil();
    HPointer succeededTask = Elm::alloc::listNil();
    {
        Elm::StackRootGuard guard(&mtpHP, &resumeHP, &posixHP, &succeededTask);

        // millisToPosix : Int -> Posix. Pass `ms` as an unboxed i64 (PK_Int)
        // via the PAP-aware typed-args entry; the runtime threads it
        // straight to wrappers that accept unboxed Int, or boxes it once at
        // the boundary for legacy wrappers — strictly less work than always
        // boxing here, and tolerates curried/partially-applied user code.
        static constexpr unsigned char kLayoutInt1[3] = { 1, 0, 1 };
        const auto* layout =
            reinterpret_cast<const Elm::EvalParamLayout*>(kLayoutInt1);
        int64_t msArg = ms;
        uint64_t posixEnc = eco_apply_closure_typed(
            HPtr::fromBits(Export::encode(mtpHP)), &msArg, 1, layout).toBits();
        posixHP = Export::decode(posixEnc);

        succeededTask = Elm::Platform::Scheduler::instance().taskSucceed(posixHP);
        Elm::Platform::Scheduler::callClosure1(resumeHP, succeededTask);
    }

    // Kill handle: Unit (Time.now is synchronous, nothing to cancel).
    return reinterpret_cast<void*>(Export::encode(Elm::alloc::unit()));
}

// Phase-8 bodies (plans/defer-eager-kernel-tasks-via-binding.md): `Time.here`
// and `Time.getZoneName` were the only stock-Elm exceptions to the deferred-
// binding rule. Both wrap the existing helpers inside a Task_Binding so the
// `localtime_r` + filesystem reads fire at scheduler-step time.
static HPointer timeHereBody(HPointer /*captured*/) {
    int offsetMinutes = getLocalTimezoneOffset();
    HPointer zone = createZone(offsetMinutes);
    return Scheduler::instance().taskSucceed(zone);
}

static HPointer timeGetZoneNameBody(HPointer /*captured*/) {
    std::string name = getTimezoneName();
    HPointer zoneName;
    if (!name.empty()) {
        zoneName = createZoneNameString(name);
    } else {
        int offsetMinutes = getLocalTimezoneOffset();
        zoneName = createZoneNameOffset(offsetMinutes);
    }
    return Scheduler::instance().taskSucceed(zoneName);
}

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_Time_now(HPtr millisToPosix) {
    // Returns Task x Posix. The clock read AND the Posix ctor application
    // are deferred into a Task_Binding so they fire each time the scheduler
    // consumes the task; otherwise every reference to Time.now would freeze
    // to the timestamp captured at module init.
    //
    // millisToPosix is captured into the binding closure so the evaluator
    // can apply `Posix : Int -> Posix` to wrap the raw ms count — the Elm
    // type is `Task x Posix`, not `Task x Int`. (Building the Posix Custom
    // by hand in C++ is also possible, but pulling the closure through is
    // the same path the JS kernel uses and it doesn't hardcode the ctor id
    // on the C++ side.)
    HPointer mtpHP = Export::decode(millisToPosix.toBits());
    HPointer bindingCB = Elm::alloc::listNil();
    HPointer task = Elm::alloc::listNil();
    {
        Elm::StackRootGuard guard(&mtpHP, &bindingCB, &task);
        // timeNowBindingEvaluator returns a boxed Task HPtr → K = PK_Boxed.
        bindingCB = Elm::alloc::allocClosureK(
            reinterpret_cast<EvalFunction>(timeNowBindingEvaluator),
            /*max_values=*/2,
            Elm::PK_Boxed);
        void* clPtr = Allocator::instance().resolve(bindingCB);
        if (clPtr) {
            Elm::alloc::closureCapture(clPtr, Elm::alloc::boxed(mtpHP), true);
        }
        task = Scheduler::instance().taskBinding(bindingCB);
    }
    return HPtr::fromBits(Export::encode(task));
}

HPtr Elm_Kernel_Time_here() {
    // Returns Task x Zone. Per Phase 8 / KERNEL_TASK_IO_001: deferred via
    // Task_Binding so the `localtime_r` call fires at scheduler-step time.
    HPointer task = Elm::Platform::makeBinding<timeHereBody>(Elm::alloc::unit());
    return HPtr::fromBits(Export::encode(task));
}

HPtr Elm_Kernel_Time_getZoneName() {
    // Returns Task x ZoneName. Per Phase 8 / KERNEL_TASK_IO_001: deferred
    // via Task_Binding so the TZ env / /etc/localtime / /etc/timezone reads
    // fire at scheduler-step time, not at module init.
    HPointer task =
        Elm::Platform::makeBinding<timeGetZoneNameBody>(Elm::alloc::unit());
    return HPtr::fromBits(Export::encode(task));
}

HPtr Elm_Kernel_Time_setInterval(double intervalMs, HPtr task) {
    // Returns a Sub descriptor (Custom type)
    // The actual timer is started by the Time effect manager's onEffects
    //
    // Sub structure:
    //   Custom { ctor: CTOR_TIME_EVERY,
    //            values: [interval (unboxed Float), tagger (boxed Closure)] }

    std::vector<Unboxable> values(2);
    values[0].f = intervalMs;                   // interval in milliseconds (unboxed)
    values[1].p = Export::decode(task.toBits()); // tagger closure (boxed)

    // Field 0 is unboxed (Float), field 1 is boxed (Closure)
    HPointer sub = custom(CTOR_TIME_EVERY, values, 0b01);
    return HPtr::fromBits(Export::encode(sub));
}

} // extern "C"
