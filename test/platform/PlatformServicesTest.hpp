#ifndef PLATFORM_SERVICES_TEST_HPP
#define PLATFORM_SERVICES_TEST_HPP

#include "../IsolatedTestRunner.hpp"

// Unit tests for the runtime platform services changed by
// plans/eco-system-library.md Phase 2: the Scheduler quiescence hook
// (step 3), TimerService::cancel (step 6), WaitService lanes / signal codes /
// unclaimed children (step 5) and the exit-code export (step 2).
//
// Fork-isolated: the Scheduler, TimerService and WaitService are process
// singletons with detached worker threads (WaitService's reaps every child of
// the process with waitpid(-1)), so they must never be started in the test
// runner process itself, whose E2E suites wait for their own children.
void registerPlatformServicesTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);

#endif  // PLATFORM_SERVICES_TEST_HPP
