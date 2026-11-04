// Unit tests of the native elm/browser and elm/file kernel stubs (BROWSER-01).
//
// Every stub was `assert(false && ...); return HPtr::fromBits(0);`: an abort with asserts on, the word 0
// escaping under NDEBUG. Decision D9: a kernel whose Task can fail (Browser.Dom getElement, getViewportOf,
// setViewportOf, focus/blur) fails it with `NotFound id`; every other one reports "<Elm function> is not
// supported natively" and exits 1, as Debug.todo does. No E2E suite depends directly on elm/browser or elm/file
// (adding one edits a shared elm.json), so the cases call `Elm_Kernel_Browser_load` and
// `Elm_Kernel_File_uploadOne` in a forked child and check its exit status and output.

#include "BrowserKernelTest.hpp"

#include "../ForkedChild.hpp"
#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/StringOps.hpp"

#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::TestHelpers;
namespace Export = Elm::Kernel::Export;

namespace {

// Returns the UTF-8 text of an encoded Elm string ("" for the Empty constant / non-pointers).
std::string elmText(uint64_t enc) {
    HPointer hp = Export::decode(enc);
    if (alloc::isEmptyString(hp)) return "";
    void* p = Export::toPtr(enc);
    if (!p) return "";
    return StringOps::toStdString(p);
}

std::string hex(uint64_t w) {
    std::ostringstream o;
    o << "0x" << std::hex << w;
    return o.str();
}

// ---------------------------------------------------------------------------
// BROWSER-01: browser-only stubs abort / return word 0 instead of a clear exit 1
// ---------------------------------------------------------------------------

#if !defined(_WIN32)
// Runs `call` in a forked child (stdout joined to the captured stderr) and fails
// unless the child exited with status 1 after printing "<elmName> is not supported natively".
void checkStubExitsClearly(const char* elmName, HPtr (*call)()) {
    ForkedChild::ChildResult r = ForkedChild::runInChild([call]() -> int {
        dup2(2, 1);
        HPtr w = call();
        std::fprintf(stderr, "stub returned word 0x%llx\n", static_cast<unsigned long long>(w.toBits()));
        return 0;
    });
    const std::string want = std::string(elmName) + " is not supported natively";
    const bool exited1 = WIFEXITED(r.status) && WEXITSTATUS(r.status) == 1;
    const bool message = r.stderrText.find(want) != std::string::npos;
    std::string how = WIFSIGNALED(r.status) ? "child killed by signal " + std::to_string(WTERMSIG(r.status))
                                            : "child exited " + std::to_string(WEXITSTATUS(r.status));
    std::string out = r.stderrText;
    if (out.size() > 300) out.resize(300);
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
    if (!(exited1 && message)) {
        TEST_FAIL("BROWSER-01: " + how + ", want exit 1 with \"" + want + "\"; output: " + out);
    }
}

HPtr callBrowserLoad() { return Elm_Kernel_Browser_load(HPtr::fromBits(Export::encode(alloc::emptyString()))); }
HPtr callFileUploadOne() { return Elm_Kernel_File_uploadOne(HPtr::fromBits(Export::encode(alloc::listNil()))); }

void testBrowserLoadUnsupported() { checkStubExitsClearly("Browser.Navigation.load", callBrowserLoad); }
void testFileSelectUnsupported() { checkStubExitsClearly("File.Select.file", callFileUploadOne); }
#endif

// Fails unless `task` is a Task that fails with `Browser.Dom.NotFound "<id>"` (ctor 0, one boxed String field).
void checkFailsNotFound(const char* what, HPtr task, const std::string& id) {
    HPointer hp = Export::decode(task.toBits());
    if (hp.ptr_ind != 0 || Export::toPtr(task.toBits()) == nullptr) {
        TEST_FAIL(std::string("BROWSER-01: ") + what + " returned a constant word " + hex(task.toBits()));
    }
    auto* t = static_cast<Task*>(Allocator::instance().resolve(hp));
    TEST_ASSERT(t->header.tag == Tag_Task);
    if (t->ctor != alloc::Task_Fail) {
        TEST_FAIL(std::string("BROWSER-01: ") + what + " returned a Task with ctor " + std::to_string(t->ctor) +
                  ", want Task_Fail");
    }
    auto* err = static_cast<Custom*>(Allocator::instance().resolve(t->value.p));
    TEST_ASSERT(err->header.tag == Tag_Custom && err->ctor == 0 && err->header.size == 1);
    TEST_ASSERT((err->unboxed & 3u) == 0);
    TEST_ASSERT(elmText(Export::encode(err->values[0].p)) == id);
}

// The Browser.Dom kernels whose Task can fail (decision D9) fail it with `NotFound id`.
void testBrowserDomFailsNotFound() {
    initAllocator();
    auto str = [](const char* t) { return HPtr::fromBits(Export::encode(alloc::allocStringFromUTF8(t))); };
    checkFailsNotFound("getElement", Elm_Kernel_Browser_getElement(str("el")), "el");
    checkFailsNotFound("getViewportOf", Elm_Kernel_Browser_getViewportOf(str("vp")), "vp");
    checkFailsNotFound("setViewportOf", Elm_Kernel_Browser_setViewportOf(str("sv"), 1.0, 2.0), "sv");
    checkFailsNotFound("call (focus)", Elm_Kernel_Browser_call(str("focus"), str("fc")), "fc");
}

}  // namespace

void registerBrowserKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if !defined(_WIN32)
    suite.add(Testing::TestCase("browser-kernel/navigation-load-exits-1-natively", testBrowserLoadUnsupported));
    suite.add(Testing::TestCase("browser-kernel/file-select-file-exits-1-natively", testFileSelectUnsupported));
#endif
    suite.add(Testing::TestCase("browser-kernel/dom-tasks-that-can-fail-fail-with-not-found", testBrowserDomFailsNotFound));
}
