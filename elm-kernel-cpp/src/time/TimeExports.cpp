//===- TimeExports.cpp - C-linkage exports for Time module -----------------===//
//
// The C-linkage kernel functions that compiled Elm code calls for elm/time: `Time.now`, `Time.here`,
// `Time.getZoneName` and `Time.setInterval`.
//
// The first three return Tasks, and a Task is a value that may be built once and run many times, or never. Reading
// the clock or the time zone when the kernel function is called would fix one reading into the Task for every run.
// So each of them returns a Binding Task, as `Elm::Platform::makeBinding` in `platform/TaskBinding.hpp` describes,
// and the reading happens each time the scheduler steps the Task. `Time.now` builds its binding by hand, because
// it has to capture the `Posix` constructor closure; the other two use `makeBinding`.
//
// The values built here are Elm custom types laid out on the GC heap:
// - a `Zone` is constructor 0 with an unboxed Int offset in minutes east of UTC, and an empty eras list;
// - a `ZoneName` is `Name String` (constructor 0) or `Offset Int` (constructor 1).
// The offset and the time-zone name are read from the operating system, with different sources per platform, set
// out at `getLocalTimezoneOffset` and `getTimezoneName`.
//
// The `Elm::Kernel::Time` functions in `Time.hpp` are unused stubs; nothing here calls them.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "TimeCtors.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "platform/Scheduler.hpp"
#include "platform/TaskBinding.hpp"
#include <chrono>
#include <ctime>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <cctype>
#include <mutex>

#if defined(__linux__) || defined(__APPLE__)
#include <sys/stat.h>
#include <unistd.h>
#endif

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;
using namespace Elm::Platform;
using Elm::Kernel::Time::CTOR_TIME_EVERY;

namespace {

/// Returns a new `Zone` whose offset is `offsetMinutes` east of UTC at all times: constructor 0 with fields
/// `[offsetMinutes (unboxed Int), []]`. The eras list, which elm/time uses for offset changes over time, is always
/// empty. A GC point.
HPointer createZone(int offsetMinutes) {
    std::vector<Unboxable> values(2);
    values[0].i = static_cast<i64>(offsetMinutes);
    values[1].p = listNil();

    // Slot kinds are 2 bits per field: field 0 is Int (1), field 1 is boxed (0).
    return custom(0, values, 0b01);
}

/// Returns a new `ZoneName` `Name name`, with `name` copied into an Elm string. A GC point.
HPointer createZoneNameString(const std::string& name) {
    HPointer nameStr = allocStringFromUTF8(name);
    std::vector<Unboxable> values(1);
    values[0].p = nameStr;
    return custom(0, values, 0);  // ctor 0 = Name, field is boxed
}

/// Returns a new `ZoneName` `Offset offsetMinutes`, with the offset as an unboxed Int. A GC point.
HPointer createZoneNameOffset(int offsetMinutes) {
    std::vector<Unboxable> values(1);
    values[0].i = static_cast<i64>(offsetMinutes);
    return custom(1, values, 1);  // ctor 1 = Offset, field is unboxed
}

/// Returns the local time zone's offset from UTC, in minutes east of UTC, at the moment of the call. The offset
/// includes daylight saving time when it is in effect.
///
/// On Linux and macOS this is `tm_gmtoff` of the current local time. On Windows it is the difference between the
/// current local time, read as if it were UTC, and the current time; `_tzset` is called once first, so that a `TZ`
/// environment variable is honoured. On any other platform it is 0.
int getLocalTimezoneOffset() {
#if defined(__linux__) || defined(__APPLE__)
    time_t now = time(nullptr);
    struct tm local_tm;
    localtime_r(&now, &local_tm);

    return static_cast<int>(local_tm.tm_gmtoff / 60);
#elif defined(_WIN32)
    static std::once_flag tzsetOnce;
    std::call_once(tzsetOnce, [] { _tzset(); });
    time_t now = time(nullptr);
    struct tm local_tm;
    if (localtime_s(&local_tm, &now) != 0) return 0;
    // `_mkgmtime` reads the broken-down local time as UTC, so the difference is the offset east of UTC.
    return static_cast<int>((_mkgmtime(&local_tm) - now) / 60);
#else
    return 0;
#endif
}

/// Returns whether `id` has the shape of an IANA time-zone id such as `Europe/Paris`, `America/Port-au-Prince` or
/// `Etc/GMT+5`: one or more components separated by single `/`, each starting with a letter and made of letters,
/// `_` and `-`, except that a final component `GMT` may be followed by a sign and digits. A POSIX rule such as
/// `CET-1CEST,M3.5.0,M10.5.0/3` or `UTC0`, and a path, do not have it.
bool isIanaShapedZoneId(const std::string& id) {
    if (id.empty() || id.front() == '/' || id.back() == '/') return false;
    size_t pos = 0;
    while (pos <= id.size()) {
        size_t slash = id.find('/', pos);
        size_t end = slash == std::string::npos ? id.size() : slash;
        std::string comp = id.substr(pos, end - pos);
        const bool last = slash == std::string::npos;
        if (comp.empty() || !std::isalpha(static_cast<unsigned char>(comp[0]))) return false;
        size_t letters = comp.size();
        if (last && comp.size() > 4 && comp.compare(0, 3, "GMT") == 0 && (comp[3] == '+' || comp[3] == '-')) {
            for (size_t i = 4; i < comp.size(); ++i) {
                if (!std::isdigit(static_cast<unsigned char>(comp[i]))) return false;
            }
            letters = 3;
        }
        for (size_t i = 0; i < letters; ++i) {
            unsigned char c = static_cast<unsigned char>(comp[i]);
            if (!std::isalpha(c) && c != '_' && c != '-') return false;
        }
        if (last) return true;
        pos = slash + 1;
    }
    return false;
}

/// Returns the zone name that the `TZ` value `tz` stands for, or an empty string if it does not name a zone.
///
/// One leading `:` is dropped. A path into a zoneinfo directory, such as `/usr/share/zoneinfo/Europe/Paris`, stands
/// for the part after `/zoneinfo/`. The value is then a name if it has the shape of an IANA id
/// (`isIanaShapedZoneId`) or, on Linux and macOS, if a file of that name exists under the zoneinfo directory
/// (`TZDIR`, or `/usr/share/zoneinfo`), which admits legacy ids such as `EST5EDT`. Anything else, such as a POSIX
/// rule like `CET-1CEST,M3.5.0,M10.5.0/3`, names no zone.
std::string zoneNameFromTz(const char* tz) {
    std::string value(tz);
    if (!value.empty() && value[0] == ':') value.erase(0, 1);
    const std::string zoneinfoPart = "/zoneinfo/";
    size_t at = value.find(zoneinfoPart);
    if (at != std::string::npos) value = value.substr(at + zoneinfoPart.size());
    if (value.empty()) return "";
    if (isIanaShapedZoneId(value)) return value;
#if defined(__linux__) || defined(__APPLE__)
    if (value[0] != '/' && value.find("..") == std::string::npos) {
        const char* dir = std::getenv("TZDIR");
        std::string path = std::string(dir && dir[0] != '\0' ? dir : "/usr/share/zoneinfo") + "/" + value;
        struct stat st;
        if (stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode)) return value;
    }
#endif
    return "";
}

/// Returns the local time zone's name, or an empty string if none is found.
///
/// If the `TZ` environment variable is set and non-empty, it alone decides: the result is the name it stands for
/// (`zoneNameFromTz`), which is empty for a value such as a POSIX rule that names no zone, so the caller falls back
/// to the offset. Otherwise:
/// - on Linux and macOS, the target of the `/etc/localtime` symbolic link, from just after `zoneinfo/`;
/// - on Linux, the first line of `/etc/timezone`, without its newline.
///
/// On Windows, nothing but `TZ` is consulted, and on any other platform the result is always empty.
std::string getTimezoneName() {
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
    const char* tz = std::getenv("TZ");
    if (tz && tz[0] != '\0') {
        return zoneNameFromTz(tz);
    }
#endif
#if defined(__linux__) || defined(__APPLE__)
    char buf[256];
    ssize_t len = readlink("/etc/localtime", buf, sizeof(buf) - 1);
    if (len > 0) {
        buf[len] = '\0';
        // A target such as /usr/share/zoneinfo/America/New_York gives America/New_York.
        const char* zoneinfo = "zoneinfo/";
        const char* found = strstr(buf, zoneinfo);
        if (found) {
            return std::string(found + strlen(zoneinfo));
        }
    }
#endif
#if defined(__linux__)
    FILE* f = fopen("/etc/timezone", "r");
    if (f) {
        char line[256];
        if (fgets(line, sizeof(line), f)) {
            fclose(f);
            size_t l = strlen(line);
            if (l > 0 && line[l-1] == '\n') line[l-1] = '\0';
            return std::string(line);
        }
        fclose(f);
    }
#endif
    // Windows names its time zones differently (e.g. "Pacific Standard Time"), and no translation to an IANA name
    // is attempted, so without `TZ` the result is empty there.
    return "";
}

/// Steps the Binding Task that `Time.now` returns: reads the system clock now, as milliseconds since the Unix
/// epoch, and applies the resume closure to a Task that succeeds with that time as a `Posix`.
///
/// `rawArgs[0]` is the encoded `millisToPosix` closure (`Int -> Posix`) that `Time.now` captured, and `rawArgs[1]`
/// is the encoded resume closure that the scheduler supplies. The count is passed through `millisToPosix` rather
/// than succeeding with a bare Int, because Elm code reads a `Posix` as a custom type and a boxed Int has a
/// different layout. Returns Unit, encoded, as the kill handle: there is nothing to cancel. A GC point.
static void* timeNowBindingEvaluator(void* rawArgs[]) {
    uint64_t mtpEnc = reinterpret_cast<uint64_t>(rawArgs[0]);
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer mtpHP = Export::decode(mtpEnc);
    HPointer resumeHP = Export::decode(resumeEnc);

    auto now = std::chrono::system_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()
    ).count();

    // Applying the closure and `taskSucceed` both allocate, so the two inputs and both intermediate results are
    // rooted for the whole block.
    HPointer posixHP = Elm::alloc::listNil();
    HPointer succeededTask = Elm::alloc::listNil();
    {
        Elm::StackRootGuard guard(&mtpHP, &resumeHP, &posixHP, &succeededTask);

        // `ms` is passed as an unboxed Int (layout kind 1) through the typed-arguments entry, which boxes it
        // only if the closure's evaluator wants it boxed, and handles a partially applied closure.
        static constexpr auto kLayoutInt1 = Elm::makeEvalParamLayout<1>(0, {1});
        const auto* layout =
            Elm::asLayout(&kLayoutInt1);
        int64_t msArg = ms;
        uint64_t posixEnc = eco_apply_closure_typed(
            HPtr::fromBits(Export::encode(mtpHP)), &msArg, 1, layout).toBits();
        posixHP = Export::decode(posixEnc);

        succeededTask = Elm::Platform::Scheduler::instance().taskSucceed(posixHP);
        Elm::Platform::Scheduler::callClosure1(resumeHP, succeededTask);
    }

    return reinterpret_cast<void*>(Export::encode(Elm::alloc::unit()));
}

/// Returns a Task that succeeds with the local `Zone`, built from the offset read at the time of the call. The
/// binding body of `Time.here`; the captured payload is Unit and is ignored. A GC point.
static HPointer timeHereBody(HPointer /*captured*/) {
    int offsetMinutes = getLocalTimezoneOffset();
    HPointer zone = createZone(offsetMinutes);
    return Scheduler::instance().taskSucceed(zone);
}

/// Returns a Task that succeeds with the local `ZoneName`: `Name` with the name `getTimezoneName` finds, or, when
/// it finds none, `Offset` with the current offset in minutes. The binding body of `Time.getZoneName`; the captured
/// payload is Unit and is ignored. A GC point.
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
    // Returns a Binding Task whose step is `timeNowBindingEvaluator`, with `millisToPosix` captured as its first
    // argument, so the clock is read each time the Task runs. Taking the `Posix` constructor from the Elm side
    // means its constructor index is not written down here.
    HPointer mtpHP = Export::decode(millisToPosix.toBits());
    HPointer bindingCB = Elm::alloc::listNil();
    HPointer task = Elm::alloc::listNil();
    {
        Elm::StackRootGuard guard(&mtpHP, &bindingCB, &task);
        // The evaluator's result, the kill handle, is a boxed value.
        bindingCB = Elm::alloc::allocClosureK(
            reinterpret_cast<EvalFunction>(timeNowBindingEvaluator),
            /*max_values=*/2,
            Elm::PK_Boxed);
        void* clPtr = Allocator::instance().resolve(bindingCB);
        Elm::alloc::closureCapture(clPtr, Elm::alloc::boxed(mtpHP), true);
        task = Scheduler::instance().taskBinding(bindingCB);
    }
    return HPtr::fromBits(Export::encode(task));
}

HPtr Elm_Kernel_Time_here() {
    // Returns a Binding Task, so the offset is read each time the Task runs.
    HPointer task = Elm::Platform::makeBinding<timeHereBody>(Elm::alloc::unit());
    return HPtr::fromBits(Export::encode(task));
}

HPtr Elm_Kernel_Time_getZoneName() {
    // Returns a Binding Task, so the environment and files are read each time the Task runs.
    HPointer task =
        Elm::Platform::makeBinding<timeGetZoneNameBody>(Elm::alloc::unit());
    return HPtr::fromBits(Export::encode(task));
}

HPtr Elm_Kernel_Time_setInterval(double intervalMs, HPtr task) {
    std::vector<Unboxable> values(2);
    values[0].f = intervalMs;
    values[1].p = Export::decode(task.toBits());

    // The kind mask gives field 0 slot kind 2 (Float) and field 1 kind 0 (boxed).
    HPointer sub = custom(CTOR_TIME_EVERY, values, 0b10);
    return HPtr::fromBits(Export::encode(sub));
}

} // extern "C"
