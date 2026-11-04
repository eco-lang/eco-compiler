// The `Eco.File` kernel: the file, directory and working-directory operations the Elm side of eco/kernel performs
// on the local file system, given to Elm as Tasks.
//
// Each function here takes the encoded words of its Elm arguments and returns the encoded word of a Task. Calling a
// function does no IO: it captures its arguments and returns a Task whose work is done each time the scheduler runs
// it, as `Eco::Kernel::makeBinding` describes, so one Task run twice acts twice. The work runs on the thread that
// steps the scheduler, and a blocking system call blocks that thread until it returns. The export of the same name
// in `KernelExports.h` forwards to each function unchanged, and its comment states what the Task succeeds with and
// how it fails; the comments below give the same contract in brief. A failure is the IO error tuple
// `(tag, path, message)` unless a comment says otherwise.
//
// Three facts hold across the module:
//
// - A path is an Elm String, passed to the operating system as its UTF-8 bytes. Every path this module returns is
//   written with forward slashes, on Windows too.
// - A handle is the operating system's file descriptor, carried as an Int in the word's bits. Nothing here records
//   which descriptors are open; a handle is valid until it is passed to `close`.
// - The write operations differ in what they report. `writeString` and `writeBytes` report only a failure to open
//   the file; `writeBytesAtomic` also reports a failure to write, close or rename it.

#ifndef ECO_FILE_HPP
#define ECO_FILE_HPP

#include <cstdint>

namespace Eco::Kernel::File {

/// Returns a Task that reads the file at `path` and succeeds with its contents as a String, taking the bytes as
/// UTF-8. It fails when the file cannot be opened, sized or read in full.
uint64_t readString(uint64_t path);
/// Returns a Task that creates or truncates the file at `path`, writes `content` to it as UTF-8, and succeeds with
/// Unit. The file is written in text mode. It fails only when the file cannot be opened.
uint64_t writeString(uint64_t path, uint64_t content);
/// Returns a Task that reads the file at `path` and succeeds with its contents as Bytes. It fails when the file
/// cannot be opened, sized or read in full, and with `EFBIG` when it is larger than 4 GiB minus one byte.
uint64_t readBytes(uint64_t path);
/// Returns a Task that creates or truncates the file at `path`, writes `bytes` to it, and succeeds with Unit. It
/// fails only when the file cannot be opened.
uint64_t writeBytes(uint64_t path, uint64_t bytes);
/// Returns a Task that writes `bytes` to a new temporary file beside `path`, renames it over `path`, and succeeds
/// with Unit. It fails when the temporary file cannot be created, written, closed or renamed, and then removes the
/// temporary file if it was created.
uint64_t writeBytesAtomic(uint64_t path, uint64_t bytes);
/// Returns a Task that opens the file at `path` and succeeds with its file descriptor as an Int. `mode` carries an
/// Int in its bits: 0 opens for reading, 1 for writing (creating or truncating), 2 for appending (creating), 3 for
/// reading and writing (creating), and any other value for reading. It fails when the file cannot be opened.
uint64_t open(uint64_t path, uint64_t mode);
/// Returns a Task that closes the file descriptor carried in `handle`'s bits and succeeds with Unit. A failure to
/// close is ignored.
uint64_t close(uint64_t handle);
/// Returns a Task that succeeds with the size in bytes of the file open as the descriptor carried in `handle`'s
/// bits. It fails, with an empty path in the error, when the size cannot be read.
uint64_t size(uint64_t handle);
/// Returns a Task that succeeds with Unit and does nothing else. No lock is taken.
uint64_t lock(uint64_t path);
/// Returns a Task that succeeds with Unit and does nothing else. No lock is released.
uint64_t unlock(uint64_t path);
/// Returns a Task that succeeds with whether `path` names a regular file. A path that cannot be examined gives
/// False.
uint64_t fileExists(uint64_t path);
/// Returns a Task that succeeds with whether `path` names a directory. A path that cannot be examined gives False.
uint64_t dirExists(uint64_t path);
/// Returns a Task that searches the directories on `PATH` in order for `name`, and succeeds with `Just` the path of
/// the first match or with `Nothing`. It does not fail.
///
/// On Windows each directory is tried with `name` as given and then with `.exe`, `.cmd`, `.bat` and `.com` added,
/// and a match is any regular file; `PATHEXT` is not read, and `Path` is read when `PATH` is not set. Elsewhere a
/// match is any path the process may execute, as `access` with `X_OK` decides.
uint64_t findExecutable(uint64_t name);
/// Returns a Task that succeeds with the names of the entries in the directory `path`, as a List of Strings in the
/// order the directory yields them. It fails when the directory cannot be opened.
uint64_t list(uint64_t path);
/// Returns a Task that succeeds with the modification time of the file at `path` as an Int count of milliseconds
/// since the Unix epoch, truncated to whole seconds on Windows. It fails when the file cannot be examined.
uint64_t modificationTime(uint64_t path);
/// Returns a Task that succeeds with the current working directory. It fails, with an empty path in the error,
/// when the directory cannot be read.
uint64_t getCwd();
/// Returns a Task that makes `path` the working directory of the whole process and succeeds with Unit. It fails
/// when the directory cannot be changed.
uint64_t setCwd(uint64_t path);
/// Returns a Task that succeeds with `path` made absolute with symbolic links resolved. When that fails, for example
/// because the path does not exist, it succeeds instead with `path` made absolute and lexically normalised, without
/// resolving links. It does not fail with an error value.
uint64_t canonicalize(uint64_t path);
/// Returns a Task that succeeds with the path of the per-user data directory for the application `name`, without
/// creating it. The path is `$HOME/.<name>`; on macOS `$HOME/Library/Application Support/<name>`; on Windows
/// `<name>` under the first of `APPDATA`, `USERPROFILE` and `HOME` that is set and not empty. It fails with a plain
/// String when there is no such variable.
uint64_t appDataDir(uint64_t name);
/// Returns a Task that creates the directory `path` and succeeds with Unit, creating missing parents too when the
/// Bool `createParents` is True. A directory that already exists is not an error. It fails when the directory
/// cannot be created.
uint64_t createDir(uint64_t createParents, uint64_t path);
/// Returns a Task that removes the file at `path` and succeeds with Unit. It fails when the file cannot be removed.
uint64_t removeFile(uint64_t path);
/// Returns a Task that removes `path` and, if it is a directory, everything beneath it, and succeeds with Unit. A
/// path that does not exist is not an error. It fails when something cannot be removed.
uint64_t removeDir(uint64_t path);
/// Returns a Task that writes `content` as UTF-8 to the file descriptor carried in `handle`'s bits and succeeds with
/// Unit. It makes one write call, so a short write is neither retried nor reported. It fails, with an empty path in
/// the error, when the write fails.
uint64_t hWriteString(uint64_t handle, uint64_t content);
/// Returns a Task that creates the file at `path` if it does not exist, sets its modification time to now, and
/// succeeds with Unit. A failure to create the file is not reported itself; the Task fails when the time cannot be
/// set.
uint64_t touch(uint64_t path);

} // namespace Eco::Kernel::File

#endif // ECO_FILE_HPP
