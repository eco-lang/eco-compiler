//===- TimeExports.cpp - C-linkage exports for Time module -----------------===//
//
// Full implementation of elm/time kernel functions.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "platform/Scheduler.hpp"
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
#endif

    // Fallback: return empty string to indicate we should use offset
    return "";
}

} // anonymous namespace

extern "C" {

uint64_t Elm_Kernel_Time_now() {
    // Returns Task x Posix
    // Posix is just an Int (milliseconds since epoch)

    auto now = std::chrono::system_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()
    ).count();

    HPointer posix = allocInt(ms);
    HPointer task = Scheduler::instance().taskSucceed(posix);
    return Export::encode(task);
}

uint64_t Elm_Kernel_Time_here() {
    // Returns Task x Zone
    // Zone is the local timezone

    int offsetMinutes = getLocalTimezoneOffset();
    HPointer zone = createZone(offsetMinutes);
    HPointer task = Scheduler::instance().taskSucceed(zone);
    return Export::encode(task);
}

uint64_t Elm_Kernel_Time_getZoneName() {
    // Returns Task x ZoneName
    // ZoneName = Name String | Offset Int

    std::string name = getTimezoneName();
    HPointer zoneName;

    if (!name.empty()) {
        zoneName = createZoneNameString(name);
    } else {
        // Fallback to offset
        int offsetMinutes = getLocalTimezoneOffset();
        zoneName = createZoneNameOffset(offsetMinutes);
    }

    HPointer task = Scheduler::instance().taskSucceed(zoneName);
    return Export::encode(task);
}

uint64_t Elm_Kernel_Time_setInterval(double intervalMs, uint64_t tagger) {
    // Returns a Sub descriptor (Custom type)
    // The actual timer is started by the Time effect manager's onEffects
    //
    // Sub structure:
    //   Custom { ctor: CTOR_TIME_EVERY,
    //            values: [interval (unboxed Float), tagger (boxed Closure)] }

    std::vector<Unboxable> values(2);
    values[0].f = intervalMs;             // interval in milliseconds (unboxed)
    values[1].p = Export::decode(tagger); // tagger closure (boxed)

    // Field 0 is unboxed (Float), field 1 is boxed (Closure)
    HPointer sub = custom(CTOR_TIME_EVERY, values, 0b01);
    return Export::encode(sub);
}

} // extern "C"
