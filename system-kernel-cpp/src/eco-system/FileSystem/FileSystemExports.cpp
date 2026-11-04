//===- FileSystemExports.cpp - C exports of Eco.Kernel.FileSystem ---------===//
//
// The `extern "C"` functions that compiled Elm code calls for the `Eco.Kernel.FileSystem` kernels. Each one
// returns a Task binding, which performs the operation each time the Task runs, and does no IO itself. The
// four directory getters return a synchronous binding over their S-mode body. Every other kernel decodes its
// arguments, packs them into the payload `packFsArgs` describes, and returns an async binding over
// `fsPoolBody`. A Bool argument arrives as the encoded True or False constant and is packed as the Int 1 or 0.
//
// Above each function is the Elm type of its kernel. The arguments arrive in the order of that type: Int as
// `int64_t`, every other value as an encoded word.
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/FileSystem.hpp"

using namespace Eco::System;
using namespace Eco::System::Fs;

extern "C" {

/// Returns the Task binding for the kernel `stat`, of Elm type `Bool -> String -> Task FErr (List Int)`.
uint64_t Eco_Kernel_FileSystem_stat(uint64_t resolveLink, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(resolveLink) ? 1 : 0);
        return enc(makeAsyncBinding<fsPoolBody<opStat, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `access`, of Elm type `Int -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_access(int64_t mode, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, mode);
        return enc(makeAsyncBinding<fsPoolBody<opAccess, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `chmod`, of Elm type `Int -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_chmod(int64_t mode, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, mode);
        return enc(makeAsyncBinding<fsPoolBody<opChmod, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `chown`, of Elm type `Bool -> Int -> Int -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_chown(uint64_t resolveLink, int64_t uid, int64_t gid, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(resolveLink) ? 1 : 0, uid, gid);
        return enc(makeAsyncBinding<fsPoolBody<opChown, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `utimes`, of Elm type `Bool -> Int -> Int -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_utimes(uint64_t resolveLink, int64_t atime, int64_t mtime, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(resolveLink) ? 1 : 0, atime, mtime);
        return enc(makeAsyncBinding<fsPoolBody<opUtimes, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `rename`, of Elm type `String -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_rename(uint64_t from, uint64_t to) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(from, to);
        return enc(makeAsyncBinding<fsPoolBody<opRename, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `realpath`, of Elm type `String -> Task FErr String`.
uint64_t Eco_Kernel_FileSystem_realpath(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opRealpath, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `copyFile`, of Elm type `String -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_copyFile(uint64_t src, uint64_t dest) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(src, dest);
        return enc(makeAsyncBinding<fsPoolBody<opCopyFile, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `appendFile`, of Elm type `Bytes -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_appendFile(uint64_t bytes, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, bytes);
        return enc(makeAsyncBinding<fsPoolBody<opAppendFile, FsKind::PathBytes>>(payload));
    )
}

/// Returns the Task binding for the kernel `readFile`, of Elm type `String -> Task FErr Bytes`.
uint64_t Eco_Kernel_FileSystem_readFile(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opReadFile, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `writeFile`, of Elm type `Bytes -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_writeFile(uint64_t bytes, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, bytes);
        return enc(makeAsyncBinding<fsPoolBody<opWriteFile, FsKind::PathBytes>>(payload));
    )
}

/// Returns the Task binding for the kernel `truncate`, of Elm type `Int -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_truncate(int64_t length, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, length);
        return enc(makeAsyncBinding<fsPoolBody<opTruncate, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `remove`, of Elm type `Bool -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_remove(uint64_t recursive, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(recursive) ? 1 : 0);
        return enc(makeAsyncBinding<fsPoolBody<opRemove, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `listDirectory`, of Elm type `String -> Task FErr (List ( String, Int ))`.
uint64_t Eco_Kernel_FileSystem_listDirectory(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opListDirectory, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `makeDirectory`, of Elm type `Bool -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_makeDirectory(uint64_t recursive, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(recursive) ? 1 : 0);
        return enc(makeAsyncBinding<fsPoolBody<opMakeDirectory, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `makeTempDirectory`, of Elm type `String -> Task FErr String`.
uint64_t Eco_Kernel_FileSystem_makeTempDirectory(uint64_t prefix) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(prefix, 0);
        return enc(makeAsyncBinding<fsPoolBody<opMakeTempDirectory, FsKind::TempDir>>(payload));
    )
}

/// Returns the Task binding for the kernel `link`, of Elm type `String -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_link(uint64_t src, uint64_t dest) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(src, dest);
        return enc(makeAsyncBinding<fsPoolBody<opLink, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `symlink`, of Elm type `String -> String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_symlink(uint64_t src, uint64_t dest) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(src, dest);
        return enc(makeAsyncBinding<fsPoolBody<opSymlink, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `readLink`, of Elm type `String -> Task FErr String`.
uint64_t Eco_Kernel_FileSystem_readLink(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opReadLink, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `unlink`, of Elm type `String -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_unlink(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opUnlink, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `open`, of Elm type `String -> String -> Task FErr Int`.
uint64_t Eco_Kernel_FileSystem_open(uint64_t flags, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, flags);
        return enc(makeAsyncBinding<fsPoolBody<opOpen, FsKind::Open>>(payload));
    )
}

/// Returns the Task binding for the kernel `close`, of Elm type `Int -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_close(int64_t fd) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd);
        return enc(makeAsyncBinding<fsPoolBody<opClose, FsKind::Close>>(payload));
    )
}

/// Returns the Task binding for the kernel `fstat`, of Elm type `Int -> Task FErr (List Int)`.
uint64_t Eco_Kernel_FileSystem_fstat(int64_t fd) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd);
        return enc(makeAsyncBinding<fsPoolBody<opFstat, FsKind::Handle>>(payload));
    )
}

/// Returns the Task binding for the kernel `fchmod`, of Elm type `Int -> Int -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_fchmod(int64_t fd, int64_t mode) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, mode);
        return enc(makeAsyncBinding<fsPoolBody<opFchmod, FsKind::Handle>>(payload));
    )
}

/// Returns the Task binding for the kernel `fchown`, of Elm type `Int -> Int -> Int -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_fchown(int64_t fd, int64_t uid, int64_t gid) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, uid, gid);
        return enc(makeAsyncBinding<fsPoolBody<opFchown, FsKind::Handle>>(payload));
    )
}

/// Returns the Task binding for the kernel `futimes`, of Elm type `Int -> Int -> Int -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_futimes(int64_t fd, int64_t atime, int64_t mtime) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, atime, mtime);
        return enc(makeAsyncBinding<fsPoolBody<opFutimes, FsKind::Handle>>(payload));
    )
}

/// Returns the Task binding for the kernel `readFromOffset`, of Elm type `Int -> Int -> Int -> Task FErr Bytes`.
uint64_t Eco_Kernel_FileSystem_readFromOffset(int64_t fd, int64_t offset, int64_t length) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, offset, length);
        return enc(makeAsyncBinding<fsPoolBody<opReadFromOffset, FsKind::Handle>>(payload));
    )
}

/// Returns the Task binding for the kernel `writeFromOffset`, of Elm type `Int -> Int -> Bytes -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_writeFromOffset(int64_t fd, int64_t offset, uint64_t bytes) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, bytes, fd, offset);
        return enc(makeAsyncBinding<fsPoolBody<opWriteFromOffset, FsKind::HandleBytes>>(payload));
    )
}

/// Returns the Task binding for the kernel `ftruncate`, of Elm type `Int -> Int -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_ftruncate(int64_t fd, int64_t length) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, length);
        return enc(makeAsyncBinding<fsPoolBody<opFtruncate, FsKind::Handle>>(payload));
    )
}

/// Returns the Task binding for the kernel `fsync`, of Elm type `Int -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_fsync(int64_t fd) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd);
        return enc(makeAsyncBinding<fsPoolBody<opFsync, FsKind::Handle>>(payload));
    )
}

/// Returns the Task binding for the kernel `fdatasync`, of Elm type `Int -> Task FErr ()`.
uint64_t Eco_Kernel_FileSystem_fdatasync(int64_t fd) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd);
        return enc(makeAsyncBinding<fsPoolBody<opFdatasync, FsKind::Handle>>(payload));
    )
}

/// Returns the Task binding for the kernel `readFileStream`, of Elm type `Int -> Int -> String -> Task FErr Int`.
uint64_t Eco_Kernel_FileSystem_readFileStream(int64_t start, int64_t endInclusive, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, start, endInclusive);
        return enc(makeAsyncBinding<fsPoolBody<opReadFileStream, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `writeFileStream`, of Elm type `Int -> Int -> String -> Task FErr Int`.
uint64_t Eco_Kernel_FileSystem_writeFileStream(int64_t mode, int64_t position, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, mode, position);
        return enc(makeAsyncBinding<fsPoolBody<opWriteFileStream, FsKind::Path>>(payload));
    )
}

/// Returns the Task binding for the kernel `homeDirectory`, of Elm type `Task Never String`.
uint64_t Eco_Kernel_FileSystem_homeDirectory() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<fsHomeDirectoryBody>(alloc::unit()));
    )
}

/// Returns the Task binding for the kernel `currentWorkingDirectory`, of Elm type `Task Never String`.
uint64_t Eco_Kernel_FileSystem_currentWorkingDirectory() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<fsCurrentWorkingDirectoryBody>(alloc::unit()));
    )
}

/// Returns the Task binding for the kernel `tmpDirectory`, of Elm type `Task Never String`.
uint64_t Eco_Kernel_FileSystem_tmpDirectory() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<fsTmpDirectoryBody>(alloc::unit()));
    )
}

/// Returns the Task binding for the kernel `devNull`, of Elm type `Task Never String`.
uint64_t Eco_Kernel_FileSystem_devNull() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<fsDevNullBody>(alloc::unit()));
    )
}

} // extern "C"
