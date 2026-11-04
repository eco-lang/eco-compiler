// Unit tests of the Debug kernel (elm-kernel-cpp/src/core/Debug).
//
// todo-message-under-capture (DEBUG-01): Elm_Kernel_Debug_todo wrote its message with eco_output_text and then
// called exit(1). Under output capture (eco_set_output_stream, which the JIT runner and the harness install) the
// text landed in the capture stream, and exit(1) never flushes or publishes that stream, so the program died
// with status 1 and no message anywhere; it now writes to stderr. The case runs Debug.todo "boom" in a forked
// child with a capture stream installed and looks for the message on the child's stderr.

#include "DebugKernelTest.hpp"

#include "../ForkedChild.hpp"
#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../elm-kernel-cpp/src/KernelExports.h"

#include <sstream>
#include <string>

#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

using namespace Elm;

namespace {

// DEBUG-01: Debug.todo's message must reach stderr even while output is captured.
void testDebugTodoMessageUnderCapture() {
#if !defined(_WIN32)
    ForkedChild::ChildResult r = ForkedChild::runInChild([] {
        ::alarm(30);   // a hang in exit() must not hang the test binary
        initAllocator();
        // The JIT runner's startOutputCapture state: a capture stream on this thread.
        eco_set_output_stream(new std::ostringstream);
        std::u16string msg = u"boom";
        HPointer s = alloc::allocString(reinterpret_cast<const u16*>(msg.data()), msg.size());
        Elm_Kernel_Debug_todo(HPtr::fromHPointer(s));
        return 42;   // not reached: Debug.todo exits
    });
    if (!WIFEXITED(r.status)) {
        TEST_FAIL("DEBUG-01: child did not exit normally (status " + std::to_string(r.status) +
                  "), stderr: " + r.stderrText);
    }
    const int code = WEXITSTATUS(r.status);
    if (code == 42) TEST_FAIL("DEBUG-01: Debug.todo returned instead of exiting");
    TEST_ASSERT(code == 1);
    if (r.stderrText.find("Debug.todo: boom") == std::string::npos) {
        TEST_FAIL("DEBUG-01: exit " + std::to_string(code) + ", stderr \"" + r.stderrText +
                  "\" (the message stayed in the never-flushed capture stream)");
    }
#endif
}

}  // namespace

void registerDebugKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase("debug-kernel/todo-message-reaches-stderr-under-output-capture",
                                testDebugTodoMessageUnderCapture));
}
