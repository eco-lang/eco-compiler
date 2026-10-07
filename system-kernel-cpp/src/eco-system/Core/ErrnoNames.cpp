//===- ErrnoNames.cpp - errno → symbolic name ("ENOENT") ------------------===//
//
// FErr codes (B2) are errno names, as in Node/gren (`error.code`).
// plans/eco-system-library.md §3.8: glibc ≥ 2.32 has strerrorname_np;
// elsewhere (musl, macOS, Windows) this table is used. Every POSIX errno is
// listed, plus the Linux and BSD/macOS extensions; each entry is guarded by
// #ifdef so the table compiles on every platform. Aliases (EWOULDBLOCK =
// EAGAIN, EDEADLOCK = EDEADLK, and EOPNOTSUPP = ENOTSUP on Linux) resolve to
// the first entry, so the preferred name comes first. ENOTSUP is reported as
// "ENOTSUP" on every platform (libuv's name; it is also the Windows stub
// code, §1). Unknown values give "UNKNOWN".
//
// Pure function; safe on any thread.
//
// Templates used: none.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"

#include <cerrno>
#include <cstring>

namespace Eco::System {

namespace {

struct ErrnoEntry {
    int code;
    const char* name;
};

const ErrnoEntry kErrnoTable[] = {
#ifdef E2BIG
    {E2BIG, "E2BIG"},
#endif
#ifdef EACCES
    {EACCES, "EACCES"},
#endif
#ifdef EADDRINUSE
    {EADDRINUSE, "EADDRINUSE"},
#endif
#ifdef EADDRNOTAVAIL
    {EADDRNOTAVAIL, "EADDRNOTAVAIL"},
#endif
#ifdef EAFNOSUPPORT
    {EAFNOSUPPORT, "EAFNOSUPPORT"},
#endif
#ifdef EAGAIN
    {EAGAIN, "EAGAIN"},
#endif
#ifdef EALREADY
    {EALREADY, "EALREADY"},
#endif
#ifdef EBADF
    {EBADF, "EBADF"},
#endif
#ifdef EBADMSG
    {EBADMSG, "EBADMSG"},
#endif
#ifdef EBUSY
    {EBUSY, "EBUSY"},
#endif
#ifdef ECANCELED
    {ECANCELED, "ECANCELED"},
#endif
#ifdef ECHILD
    {ECHILD, "ECHILD"},
#endif
#ifdef ECONNABORTED
    {ECONNABORTED, "ECONNABORTED"},
#endif
#ifdef ECONNREFUSED
    {ECONNREFUSED, "ECONNREFUSED"},
#endif
#ifdef ECONNRESET
    {ECONNRESET, "ECONNRESET"},
#endif
#ifdef EDEADLK
    {EDEADLK, "EDEADLK"},
#endif
#ifdef EDESTADDRREQ
    {EDESTADDRREQ, "EDESTADDRREQ"},
#endif
#ifdef EDOM
    {EDOM, "EDOM"},
#endif
#ifdef EDQUOT
    {EDQUOT, "EDQUOT"},
#endif
#ifdef EEXIST
    {EEXIST, "EEXIST"},
#endif
#ifdef EFAULT
    {EFAULT, "EFAULT"},
#endif
#ifdef EFBIG
    {EFBIG, "EFBIG"},
#endif
#ifdef EHOSTUNREACH
    {EHOSTUNREACH, "EHOSTUNREACH"},
#endif
#ifdef EIDRM
    {EIDRM, "EIDRM"},
#endif
#ifdef EILSEQ
    {EILSEQ, "EILSEQ"},
#endif
#ifdef EINPROGRESS
    {EINPROGRESS, "EINPROGRESS"},
#endif
#ifdef EINTR
    {EINTR, "EINTR"},
#endif
#ifdef EINVAL
    {EINVAL, "EINVAL"},
#endif
#ifdef EIO
    {EIO, "EIO"},
#endif
#ifdef EISCONN
    {EISCONN, "EISCONN"},
#endif
#ifdef EISDIR
    {EISDIR, "EISDIR"},
#endif
#ifdef ELOOP
    {ELOOP, "ELOOP"},
#endif
#ifdef EMFILE
    {EMFILE, "EMFILE"},
#endif
#ifdef EMLINK
    {EMLINK, "EMLINK"},
#endif
#ifdef EMSGSIZE
    {EMSGSIZE, "EMSGSIZE"},
#endif
#ifdef EMULTIHOP
    {EMULTIHOP, "EMULTIHOP"},
#endif
#ifdef ENAMETOOLONG
    {ENAMETOOLONG, "ENAMETOOLONG"},
#endif
#ifdef ENETDOWN
    {ENETDOWN, "ENETDOWN"},
#endif
#ifdef ENETRESET
    {ENETRESET, "ENETRESET"},
#endif
#ifdef ENETUNREACH
    {ENETUNREACH, "ENETUNREACH"},
#endif
#ifdef ENFILE
    {ENFILE, "ENFILE"},
#endif
#ifdef ENOBUFS
    {ENOBUFS, "ENOBUFS"},
#endif
#ifdef ENODATA
    {ENODATA, "ENODATA"},
#endif
#ifdef ENODEV
    {ENODEV, "ENODEV"},
#endif
#ifdef ENOENT
    {ENOENT, "ENOENT"},
#endif
#ifdef ENOEXEC
    {ENOEXEC, "ENOEXEC"},
#endif
#ifdef ENOLCK
    {ENOLCK, "ENOLCK"},
#endif
#ifdef ENOLINK
    {ENOLINK, "ENOLINK"},
#endif
#ifdef ENOMEM
    {ENOMEM, "ENOMEM"},
#endif
#ifdef ENOMSG
    {ENOMSG, "ENOMSG"},
#endif
#ifdef ENOPROTOOPT
    {ENOPROTOOPT, "ENOPROTOOPT"},
#endif
#ifdef ENOSPC
    {ENOSPC, "ENOSPC"},
#endif
#ifdef ENOSR
    {ENOSR, "ENOSR"},
#endif
#ifdef ENOSTR
    {ENOSTR, "ENOSTR"},
#endif
#ifdef ENOSYS
    {ENOSYS, "ENOSYS"},
#endif
#ifdef ENOTCONN
    {ENOTCONN, "ENOTCONN"},
#endif
#ifdef ENOTDIR
    {ENOTDIR, "ENOTDIR"},
#endif
#ifdef ENOTEMPTY
    {ENOTEMPTY, "ENOTEMPTY"},
#endif
#ifdef ENOTRECOVERABLE
    {ENOTRECOVERABLE, "ENOTRECOVERABLE"},
#endif
#ifdef ENOTSOCK
    {ENOTSOCK, "ENOTSOCK"},
#endif
#ifdef ENOTSUP
    {ENOTSUP, "ENOTSUP"},
#endif
#ifdef ENOTTY
    {ENOTTY, "ENOTTY"},
#endif
#ifdef ENXIO
    {ENXIO, "ENXIO"},
#endif
#ifdef EOPNOTSUPP
    {EOPNOTSUPP, "EOPNOTSUPP"},
#endif
#ifdef EOVERFLOW
    {EOVERFLOW, "EOVERFLOW"},
#endif
#ifdef EOWNERDEAD
    {EOWNERDEAD, "EOWNERDEAD"},
#endif
#ifdef EPERM
    {EPERM, "EPERM"},
#endif
#ifdef EPIPE
    {EPIPE, "EPIPE"},
#endif
#ifdef EPROTO
    {EPROTO, "EPROTO"},
#endif
#ifdef EPROTONOSUPPORT
    {EPROTONOSUPPORT, "EPROTONOSUPPORT"},
#endif
#ifdef EPROTOTYPE
    {EPROTOTYPE, "EPROTOTYPE"},
#endif
#ifdef ERANGE
    {ERANGE, "ERANGE"},
#endif
#ifdef EROFS
    {EROFS, "EROFS"},
#endif
#ifdef ESPIPE
    {ESPIPE, "ESPIPE"},
#endif
#ifdef ESRCH
    {ESRCH, "ESRCH"},
#endif
#ifdef ESTALE
    {ESTALE, "ESTALE"},
#endif
#ifdef ETIME
    {ETIME, "ETIME"},
#endif
#ifdef ETIMEDOUT
    {ETIMEDOUT, "ETIMEDOUT"},
#endif
#ifdef ETXTBSY
    {ETXTBSY, "ETXTBSY"},
#endif
#ifdef EWOULDBLOCK
    {EWOULDBLOCK, "EWOULDBLOCK"},
#endif
#ifdef EXDEV
    {EXDEV, "EXDEV"},
#endif
#ifdef EHOSTDOWN
    {EHOSTDOWN, "EHOSTDOWN"},
#endif
#ifdef ESHUTDOWN
    {ESHUTDOWN, "ESHUTDOWN"},
#endif
#ifdef ETOOMANYREFS
    {ETOOMANYREFS, "ETOOMANYREFS"},
#endif
#ifdef ESOCKTNOSUPPORT
    {ESOCKTNOSUPPORT, "ESOCKTNOSUPPORT"},
#endif
#ifdef EPFNOSUPPORT
    {EPFNOSUPPORT, "EPFNOSUPPORT"},
#endif
#ifdef EUSERS
    {EUSERS, "EUSERS"},
#endif
#ifdef EREMOTE
    {EREMOTE, "EREMOTE"},
#endif
#ifdef ENOTBLK
    {ENOTBLK, "ENOTBLK"},
#endif
#ifdef ECHRNG
    {ECHRNG, "ECHRNG"},
#endif
#ifdef EL2NSYNC
    {EL2NSYNC, "EL2NSYNC"},
#endif
#ifdef EL3HLT
    {EL3HLT, "EL3HLT"},
#endif
#ifdef EL3RST
    {EL3RST, "EL3RST"},
#endif
#ifdef ELNRNG
    {ELNRNG, "ELNRNG"},
#endif
#ifdef EUNATCH
    {EUNATCH, "EUNATCH"},
#endif
#ifdef ENOCSI
    {ENOCSI, "ENOCSI"},
#endif
#ifdef EL2HLT
    {EL2HLT, "EL2HLT"},
#endif
#ifdef EBADE
    {EBADE, "EBADE"},
#endif
#ifdef EBADR
    {EBADR, "EBADR"},
#endif
#ifdef EXFULL
    {EXFULL, "EXFULL"},
#endif
#ifdef ENOANO
    {ENOANO, "ENOANO"},
#endif
#ifdef EBADRQC
    {EBADRQC, "EBADRQC"},
#endif
#ifdef EBADSLT
    {EBADSLT, "EBADSLT"},
#endif
#ifdef EDEADLOCK
    {EDEADLOCK, "EDEADLOCK"},
#endif
#ifdef EBFONT
    {EBFONT, "EBFONT"},
#endif
#ifdef ENONET
    {ENONET, "ENONET"},
#endif
#ifdef ENOPKG
    {ENOPKG, "ENOPKG"},
#endif
#ifdef EADV
    {EADV, "EADV"},
#endif
#ifdef ESRMNT
    {ESRMNT, "ESRMNT"},
#endif
#ifdef ECOMM
    {ECOMM, "ECOMM"},
#endif
#ifdef EDOTDOT
    {EDOTDOT, "EDOTDOT"},
#endif
#ifdef ENOTUNIQ
    {ENOTUNIQ, "ENOTUNIQ"},
#endif
#ifdef EBADFD
    {EBADFD, "EBADFD"},
#endif
#ifdef EREMCHG
    {EREMCHG, "EREMCHG"},
#endif
#ifdef ELIBACC
    {ELIBACC, "ELIBACC"},
#endif
#ifdef ELIBBAD
    {ELIBBAD, "ELIBBAD"},
#endif
#ifdef ELIBSCN
    {ELIBSCN, "ELIBSCN"},
#endif
#ifdef ELIBMAX
    {ELIBMAX, "ELIBMAX"},
#endif
#ifdef ELIBEXEC
    {ELIBEXEC, "ELIBEXEC"},
#endif
#ifdef ERESTART
    {ERESTART, "ERESTART"},
#endif
#ifdef ESTRPIPE
    {ESTRPIPE, "ESTRPIPE"},
#endif
#ifdef EUCLEAN
    {EUCLEAN, "EUCLEAN"},
#endif
#ifdef ENOTNAM
    {ENOTNAM, "ENOTNAM"},
#endif
#ifdef ENAVAIL
    {ENAVAIL, "ENAVAIL"},
#endif
#ifdef EISNAM
    {EISNAM, "EISNAM"},
#endif
#ifdef EREMOTEIO
    {EREMOTEIO, "EREMOTEIO"},
#endif
#ifdef ENOMEDIUM
    {ENOMEDIUM, "ENOMEDIUM"},
#endif
#ifdef EMEDIUMTYPE
    {EMEDIUMTYPE, "EMEDIUMTYPE"},
#endif
#ifdef ENOKEY
    {ENOKEY, "ENOKEY"},
#endif
#ifdef EKEYEXPIRED
    {EKEYEXPIRED, "EKEYEXPIRED"},
#endif
#ifdef EKEYREVOKED
    {EKEYREVOKED, "EKEYREVOKED"},
#endif
#ifdef EKEYREJECTED
    {EKEYREJECTED, "EKEYREJECTED"},
#endif
#ifdef ERFKILL
    {ERFKILL, "ERFKILL"},
#endif
#ifdef EHWPOISON
    {EHWPOISON, "EHWPOISON"},
#endif
#ifdef EAUTH
    {EAUTH, "EAUTH"},
#endif
#ifdef EBADARCH
    {EBADARCH, "EBADARCH"},
#endif
#ifdef EBADEXEC
    {EBADEXEC, "EBADEXEC"},
#endif
#ifdef EBADMACHO
    {EBADMACHO, "EBADMACHO"},
#endif
#ifdef EBADRPC
    {EBADRPC, "EBADRPC"},
#endif
#ifdef EDEVERR
    {EDEVERR, "EDEVERR"},
#endif
#ifdef EFTYPE
    {EFTYPE, "EFTYPE"},
#endif
#ifdef ENEEDAUTH
    {ENEEDAUTH, "ENEEDAUTH"},
#endif
#ifdef ENOATTR
    {ENOATTR, "ENOATTR"},
#endif
#ifdef ENOPOLICY
    {ENOPOLICY, "ENOPOLICY"},
#endif
#ifdef EPROCLIM
    {EPROCLIM, "EPROCLIM"},
#endif
#ifdef EPROCUNAVAIL
    {EPROCUNAVAIL, "EPROCUNAVAIL"},
#endif
#ifdef EPROGMISMATCH
    {EPROGMISMATCH, "EPROGMISMATCH"},
#endif
#ifdef EPROGUNAVAIL
    {EPROGUNAVAIL, "EPROGUNAVAIL"},
#endif
#ifdef EPWROFF
    {EPWROFF, "EPWROFF"},
#endif
#ifdef ERPCMISMATCH
    {ERPCMISMATCH, "ERPCMISMATCH"},
#endif
#ifdef ESHLIBVERS
    {ESHLIBVERS, "ESHLIBVERS"},
#endif
#ifdef EQFULL
    {EQFULL, "EQFULL"},
#endif
};

} // namespace

const char* errnoName(int err) {
#ifdef ENOTSUP
    if (err == ENOTSUP) return "ENOTSUP";
#endif
#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 32))
    if (const char* n = ::strerrorname_np(err)) return n;
#endif
    for (const auto& e : kErrnoTable) {
        if (e.code == err) return e.name;
    }
    return "UNKNOWN";
}

} // namespace Eco::System
