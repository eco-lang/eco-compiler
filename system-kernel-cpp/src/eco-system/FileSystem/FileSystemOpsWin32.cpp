//===- FileSystemOpsWin32.cpp - Windows stubs of Eco.Kernel.FileSystem ----===//
//
// File system operations are not implemented on Windows; these stubs keep the module linking. Each worker
// operation fails with errno ENOTSUP. The failure gives "eco/system" as the failing call's name and the operation's
// `s1` slot as the path, so the message ends ", eco/system '<s1>'", or ", eco/system" when `s1` is empty.
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/FileSystem.hpp"

#include <cerrno>

namespace Eco::System::Fs {

namespace {

// Returns the ENOTSUP failure every operation here gives, quoting `a.s1`.
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
