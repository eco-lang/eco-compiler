/**
 * Elm Kernel Time Module - Runtime Heap Integration
 *
 * Provides time-related operations using GC-managed heap values.
 */

#include "Time.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include <chrono>
#include <thread>
#include <atomic>
#include <ctime>
#include <cstdlib>

namespace Elm::Kernel::Time {

// Time zone variant type ID
constexpr u16 TIME_ZONE_TYPE_ID = 1;

TaskPtr now() {
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        auto nowTime = std::chrono::system_clock::now();
        auto epochTime = nowTime.time_since_epoch();
        auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(epochTime).count();

        // Create Posix value (just an Int in Elm)
        HPointer posixValue = alloc::allocInt(millis);
        callback(posixValue);

        return []() {}; // No cancellation
    });
}

TaskPtr here() {
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Get timezone offset using C time functions
        std::time_t now = std::time(nullptr);
        std::tm local_tm;
        std::tm utc_tm;

#ifdef _WIN32
        localtime_s(&local_tm, &now);
        gmtime_s(&utc_tm, &now);
#else
        localtime_r(&now, &local_tm);
        gmtime_r(&now, &utc_tm);
#endif

        // Calculate offset in minutes
        int local_minutes = local_tm.tm_hour * 60 + local_tm.tm_min;
        int utc_minutes = utc_tm.tm_hour * 60 + utc_tm.tm_min;

        // Handle day boundary
        int day_diff = local_tm.tm_yday - utc_tm.tm_yday;
        if (day_diff > 1) day_diff = -1;  // Year boundary
        if (day_diff < -1) day_diff = 1;

        int offset = local_minutes - utc_minutes + day_diff * 24 * 60;

        // Create Zone value (just returning offset as Int for simplicity)
        HPointer zoneValue = alloc::allocInt(offset);
        callback(zoneValue);

        return []() {};
    });
}

TaskPtr getZoneName() {
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Try to get timezone name from environment
        const char* tz = std::getenv("TZ");

        if (tz != nullptr && tz[0] != '\0') {
            // Return Name variant: { ctor: 0, value: tzName }
            HPointer tzNameStr = alloc::allocStringFromUTF8(tz);
            HPointer nameVariant = alloc::custom(TIME_ZONE_TYPE_ID, 0, {alloc::boxed(tzNameStr)}, 0);
            callback(nameVariant);
        } else {
            // Return Offset variant: { ctor: 1, value: offset }
            std::time_t now = std::time(nullptr);
            std::tm local_tm;
            std::tm utc_tm;

#ifdef _WIN32
            localtime_s(&local_tm, &now);
            gmtime_s(&utc_tm, &now);
#else
            localtime_r(&now, &local_tm);
            gmtime_r(&now, &utc_tm);
#endif

            int local_minutes = local_tm.tm_hour * 60 + local_tm.tm_min;
            int utc_minutes = utc_tm.tm_hour * 60 + utc_tm.tm_min;
            int offset = local_minutes - utc_minutes;

            // Create Offset variant: { ctor: 1, value: offset }
            HPointer offsetVariant = alloc::custom(TIME_ZONE_TYPE_ID, 1, {alloc::unboxedInt(static_cast<i64>(offset))}, 0x1);
            callback(offsetVariant);
        }

        return []() {};
    });
}

TaskPtr setInterval(f64 intervalMs, TaskPtr task) {
    return Scheduler::binding([intervalMs, task](Scheduler::Callback callback) -> std::function<void()> {
        // Create a flag to track if the interval should stop
        auto running = std::make_shared<std::atomic<bool>>(true);

        // Start a thread that runs the interval
        std::thread([intervalMs, task, running]() {
            while (running->load()) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(static_cast<int64_t>(intervalMs))
                );

                if (running->load()) {
                    // Spawn the task
                    Scheduler::rawSpawn(task);
                }
            }
        }).detach();

        // Return kill function
        return [running]() {
            running->store(false);
        };
    });
}

} // namespace Elm::Kernel::Time
