//===- FileSystemExports.cpp - C exports of Eco.Kernel.FileSystem ---------===//
//
// plans/eco-system-library.md Appendix B.3. Each export only decodes its
// arguments and packs them (packFsArgs, FileSystem.hpp) into one payload,
// then returns a binding (G2): P mode (makeAsyncBinding + the T2 pool body)
// for everything but the four directory getters, which are S mode
// (makeBinding, T1). Bool arguments arrive as encoded constants and are
// packed as 0/1 Ints. The `System.File` effect manager registration is in
// FileSystemManager.cpp.
//
// Templates used: T1, T2.
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/FileSystem.hpp"

using namespace Eco::System;
using namespace Eco::System::Fs;

extern "C" {

// stat : Bool -> String -> Task FErr (List Int)
uint64_t Eco_Kernel_FileSystem_stat(uint64_t resolveLink, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(resolveLink) ? 1 : 0);
        return enc(makeAsyncBinding<fsPoolBody<opStat, FsKind::Path>>(payload));
    )
}

// access : Int -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_access(int64_t mode, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, mode);
        return enc(makeAsyncBinding<fsPoolBody<opAccess, FsKind::Path>>(payload));
    )
}

// chmod : Int -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_chmod(int64_t mode, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, mode);
        return enc(makeAsyncBinding<fsPoolBody<opChmod, FsKind::Path>>(payload));
    )
}

// chown : Bool -> Int -> Int -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_chown(uint64_t resolveLink, int64_t uid, int64_t gid, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(resolveLink) ? 1 : 0, uid, gid);
        return enc(makeAsyncBinding<fsPoolBody<opChown, FsKind::Path>>(payload));
    )
}

// utimes : Bool -> Int -> Int -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_utimes(uint64_t resolveLink, int64_t atime, int64_t mtime, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(resolveLink) ? 1 : 0, atime, mtime);
        return enc(makeAsyncBinding<fsPoolBody<opUtimes, FsKind::Path>>(payload));
    )
}

// rename : String -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_rename(uint64_t from, uint64_t to) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(from, to);
        return enc(makeAsyncBinding<fsPoolBody<opRename, FsKind::Path>>(payload));
    )
}

// realpath : String -> Task FErr String
uint64_t Eco_Kernel_FileSystem_realpath(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opRealpath, FsKind::Path>>(payload));
    )
}

// copyFile : String -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_copyFile(uint64_t src, uint64_t dest) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(src, dest);
        return enc(makeAsyncBinding<fsPoolBody<opCopyFile, FsKind::Path>>(payload));
    )
}

// appendFile : Bytes -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_appendFile(uint64_t bytes, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, bytes);
        return enc(makeAsyncBinding<fsPoolBody<opAppendFile, FsKind::PathBytes>>(payload));
    )
}

// readFile : String -> Task FErr Bytes
uint64_t Eco_Kernel_FileSystem_readFile(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opReadFile, FsKind::Path>>(payload));
    )
}

// writeFile : Bytes -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_writeFile(uint64_t bytes, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, bytes);
        return enc(makeAsyncBinding<fsPoolBody<opWriteFile, FsKind::PathBytes>>(payload));
    )
}

// truncate : Int -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_truncate(int64_t length, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, length);
        return enc(makeAsyncBinding<fsPoolBody<opTruncate, FsKind::Path>>(payload));
    )
}

// remove : Bool -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_remove(uint64_t recursive, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(recursive) ? 1 : 0);
        return enc(makeAsyncBinding<fsPoolBody<opRemove, FsKind::Path>>(payload));
    )
}

// listDirectory : String -> Task FErr (List ( String, Int ))
uint64_t Eco_Kernel_FileSystem_listDirectory(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opListDirectory, FsKind::Path>>(payload));
    )
}

// makeDirectory : Bool -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_makeDirectory(uint64_t recursive, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, Export::decodeBoxedBool(recursive) ? 1 : 0);
        return enc(makeAsyncBinding<fsPoolBody<opMakeDirectory, FsKind::Path>>(payload));
    )
}

// makeTempDirectory : String -> Task FErr String
uint64_t Eco_Kernel_FileSystem_makeTempDirectory(uint64_t prefix) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(prefix, 0);
        return enc(makeAsyncBinding<fsPoolBody<opMakeTempDirectory, FsKind::TempDir>>(payload));
    )
}

// link : String -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_link(uint64_t src, uint64_t dest) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(src, dest);
        return enc(makeAsyncBinding<fsPoolBody<opLink, FsKind::Path>>(payload));
    )
}

// symlink : String -> String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_symlink(uint64_t src, uint64_t dest) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(src, dest);
        return enc(makeAsyncBinding<fsPoolBody<opSymlink, FsKind::Path>>(payload));
    )
}

// readLink : String -> Task FErr String
uint64_t Eco_Kernel_FileSystem_readLink(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opReadLink, FsKind::Path>>(payload));
    )
}

// unlink : String -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_unlink(uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0);
        return enc(makeAsyncBinding<fsPoolBody<opUnlink, FsKind::Path>>(payload));
    )
}

// open : String -> String -> Task FErr Int
uint64_t Eco_Kernel_FileSystem_open(uint64_t flags, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, flags);
        return enc(makeAsyncBinding<fsPoolBody<opOpen, FsKind::Open>>(payload));
    )
}

// close : Int -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_close(int64_t fd) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd);
        return enc(makeAsyncBinding<fsPoolBody<opClose, FsKind::Close>>(payload));
    )
}

// fstat : Int -> Task FErr (List Int)
uint64_t Eco_Kernel_FileSystem_fstat(int64_t fd) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd);
        return enc(makeAsyncBinding<fsPoolBody<opFstat, FsKind::Handle>>(payload));
    )
}

// fchmod : Int -> Int -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_fchmod(int64_t fd, int64_t mode) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, mode);
        return enc(makeAsyncBinding<fsPoolBody<opFchmod, FsKind::Handle>>(payload));
    )
}

// fchown : Int -> Int -> Int -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_fchown(int64_t fd, int64_t uid, int64_t gid) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, uid, gid);
        return enc(makeAsyncBinding<fsPoolBody<opFchown, FsKind::Handle>>(payload));
    )
}

// futimes : Int -> Int -> Int -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_futimes(int64_t fd, int64_t atime, int64_t mtime) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, atime, mtime);
        return enc(makeAsyncBinding<fsPoolBody<opFutimes, FsKind::Handle>>(payload));
    )
}

// readFromOffset : Int -> Int -> Int -> Task FErr Bytes
uint64_t Eco_Kernel_FileSystem_readFromOffset(int64_t fd, int64_t offset, int64_t length) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, offset, length);
        return enc(makeAsyncBinding<fsPoolBody<opReadFromOffset, FsKind::Handle>>(payload));
    )
}

// writeFromOffset : Int -> Int -> Bytes -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_writeFromOffset(int64_t fd, int64_t offset, uint64_t bytes) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, bytes, fd, offset);
        return enc(makeAsyncBinding<fsPoolBody<opWriteFromOffset, FsKind::HandleBytes>>(payload));
    )
}

// ftruncate : Int -> Int -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_ftruncate(int64_t fd, int64_t length) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd, length);
        return enc(makeAsyncBinding<fsPoolBody<opFtruncate, FsKind::Handle>>(payload));
    )
}

// fsync : Int -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_fsync(int64_t fd) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd);
        return enc(makeAsyncBinding<fsPoolBody<opFsync, FsKind::Handle>>(payload));
    )
}

// fdatasync : Int -> Task FErr ()
uint64_t Eco_Kernel_FileSystem_fdatasync(int64_t fd) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(0, 0, fd);
        return enc(makeAsyncBinding<fsPoolBody<opFdatasync, FsKind::Handle>>(payload));
    )
}

// readFileStream : Int -> Int -> String -> Task FErr Int
uint64_t Eco_Kernel_FileSystem_readFileStream(int64_t start, int64_t endInclusive, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, start, endInclusive);
        return enc(makeAsyncBinding<fsPoolBody<opReadFileStream, FsKind::Path>>(payload));
    )
}

// writeFileStream : Int -> Int -> String -> Task FErr Int
uint64_t Eco_Kernel_FileSystem_writeFileStream(int64_t mode, int64_t position, uint64_t path) {
    ECO_KERNEL_GUARD(
        HPointer payload = packFsArgs(path, 0, mode, position);
        return enc(makeAsyncBinding<fsPoolBody<opWriteFileStream, FsKind::Path>>(payload));
    )
}

// homeDirectory : Task Never String
uint64_t Eco_Kernel_FileSystem_homeDirectory() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<fsHomeDirectoryBody>(alloc::unit()));
    )
}

// currentWorkingDirectory : Task Never String
uint64_t Eco_Kernel_FileSystem_currentWorkingDirectory() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<fsCurrentWorkingDirectoryBody>(alloc::unit()));
    )
}

// tmpDirectory : Task Never String
uint64_t Eco_Kernel_FileSystem_tmpDirectory() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<fsTmpDirectoryBody>(alloc::unit()));
    )
}

// devNull : Task Never String
uint64_t Eco_Kernel_FileSystem_devNull() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<fsDevNullBody>(alloc::unit()));
    )
}

} // extern "C"
