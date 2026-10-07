//===- FileSystemOpsWin32.cpp - Windows stubs of Eco.Kernel.FileSystem ----===//
//
// plans/eco-system-library.md §1: Windows is out of scope for now. Every
// fallible file system task fails with the error code "ENOTSUP"; the four
// directory getters (FileSystem.cpp) work.
//
// Templates used: none (POD only).
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/FileSystem.hpp"

#include <cerrno>

namespace Eco::System::Fs {

namespace {

FsRes unsupported(const FsArgs& a) {
    return FsRes::fail(ENOTSUP, "eco/system", a.s1);
}

} // namespace

FsRes opStat(const FsArgs& a) { return unsupported(a); }
FsRes opAccess(const FsArgs& a) { return unsupported(a); }
FsRes opChmod(const FsArgs& a) { return unsupported(a); }
FsRes opChown(const FsArgs& a) { return unsupported(a); }
FsRes opUtimes(const FsArgs& a) { return unsupported(a); }
FsRes opRename(const FsArgs& a) { return unsupported(a); }
FsRes opRealpath(const FsArgs& a) { return unsupported(a); }
FsRes opCopyFile(const FsArgs& a) { return unsupported(a); }
FsRes opAppendFile(const FsArgs& a) { return unsupported(a); }
FsRes opReadFile(const FsArgs& a) { return unsupported(a); }
FsRes opWriteFile(const FsArgs& a) { return unsupported(a); }
FsRes opTruncate(const FsArgs& a) { return unsupported(a); }
FsRes opRemove(const FsArgs& a) { return unsupported(a); }
FsRes opListDirectory(const FsArgs& a) { return unsupported(a); }
FsRes opMakeDirectory(const FsArgs& a) { return unsupported(a); }
FsRes opMakeTempDirectory(const FsArgs& a) { return unsupported(a); }
FsRes opLink(const FsArgs& a) { return unsupported(a); }
FsRes opSymlink(const FsArgs& a) { return unsupported(a); }
FsRes opReadLink(const FsArgs& a) { return unsupported(a); }
FsRes opUnlink(const FsArgs& a) { return unsupported(a); }
FsRes opOpen(const FsArgs& a) { return unsupported(a); }
FsRes opClose(const FsArgs& a) { return unsupported(a); }
FsRes opFstat(const FsArgs& a) { return unsupported(a); }
FsRes opFchmod(const FsArgs& a) { return unsupported(a); }
FsRes opFchown(const FsArgs& a) { return unsupported(a); }
FsRes opFutimes(const FsArgs& a) { return unsupported(a); }
FsRes opReadFromOffset(const FsArgs& a) { return unsupported(a); }
FsRes opWriteFromOffset(const FsArgs& a) { return unsupported(a); }
FsRes opFtruncate(const FsArgs& a) { return unsupported(a); }
FsRes opFsync(const FsArgs& a) { return unsupported(a); }
FsRes opFdatasync(const FsArgs& a) { return unsupported(a); }
FsRes opReadFileStream(const FsArgs& a) { return unsupported(a); }
FsRes opWriteFileStream(const FsArgs& a) { return unsupported(a); }

} // namespace Eco::System::Fs
