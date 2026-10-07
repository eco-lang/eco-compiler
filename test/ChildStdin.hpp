// ChildStdin.hpp — stdin plumbing for forked E2E test children
// (plans/eco-system-library.md Phase 1 step 8c).
//
// Called in a child between fork() and running the program:
//   - no `-- STDIN:` text: stdin becomes /dev/null, so a program that reads
//     stdin sees EOF instead of blocking on (or stealing) the runner's stdin;
//   - with text: stdin becomes the read end of a pipe that already holds the
//     whole text and whose write end is closed, so the program reads the text
//     and then EOF.
//
// The text is written before the program starts, so it must fit in the pipe
// buffer (64 KiB by default; on Linux the buffer is grown with F_SETPIPE_SZ
// up to the system limit). Larger text is reported as an error instead of
// blocking the child.
#pragma once

#if !defined(_WIN32)

#include <cerrno>
#include <cstring>
#include <optional>
#include <string>

#include <fcntl.h>
#include <unistd.h>

namespace eco_test {

/// Replaces fd 0 of the calling (child) process. Returns "" on success, or an
/// error message.
inline std::string redirectChildStdin(const std::optional<std::string>& text) {
    if (!text) {
        int fd = ::open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (fd < 0) return std::string("open(/dev/null): ") + std::strerror(errno);
        if (fd == STDIN_FILENO) {
            // stdin was closed and open() reused fd 0: keep it, open across exec.
            (void)::fcntl(fd, F_SETFD, 0);
            return "";
        }
        if (::dup2(fd, STDIN_FILENO) < 0) {
            int e = errno;
            ::close(fd);
            return std::string("dup2(stdin): ") + std::strerror(e);
        }
        ::close(fd);
        return "";
    }

    int p[2];
    if (::pipe(p) < 0) return std::string("pipe(stdin): ") + std::strerror(errno);
#if defined(F_SETPIPE_SZ)
    if (text->size() > 65536) {
        (void)::fcntl(p[1], F_SETPIPE_SZ, static_cast<int>(text->size()));
    }
#endif
    int flags = ::fcntl(p[1], F_GETFL);
    if (flags >= 0) (void)::fcntl(p[1], F_SETFL, flags | O_NONBLOCK);

    const char* data = text->data();
    size_t left = text->size();
    while (left > 0) {
        ssize_t n = ::write(p[1], data, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            ::close(p[0]);
            ::close(p[1]);
            if (e == EAGAIN || e == EWOULDBLOCK) {
                return "STDIN directive text (" + std::to_string(text->size()) +
                       " bytes) does not fit in the stdin pipe buffer";
            }
            return std::string("write(stdin pipe): ") + std::strerror(e);
        }
        data += n;
        left -= static_cast<size_t>(n);
    }
    ::close(p[1]);
    if (p[0] == STDIN_FILENO) return "";  // stdin was closed; pipe() reused fd 0
    if (::dup2(p[0], STDIN_FILENO) < 0) {
        int e = errno;
        ::close(p[0]);
        return std::string("dup2(stdin): ") + std::strerror(e);
    }
    ::close(p[0]);
    return "";
}

} // namespace eco_test

#endif // !_WIN32
