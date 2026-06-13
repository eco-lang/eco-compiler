// Minimal getopt_long shim for Windows builds of the GC test runner. The
// MSVC CRT has no getopt; this is a pragmatic ~120-line drop-in that
// covers exactly the surface test/main.cpp uses: getopt_long with the
// no_argument / required_argument flag forms, an `optarg` global, and the
// standard "returns -1 at end" contract.
//
// NOT a full POSIX implementation: no optional_argument, no permutation, no
// GNU "+"/"-" prefix handling. Good enough for the test runner's argv
// shape; everywhere else we'd reach for getopt should go through the same
// pattern.
//
// Used only when the test binary is being compiled on Windows; the real
// system <getopt.h> wins on Linux/macOS via the include-path ordering in
// test/CMakeLists.txt.

#ifndef ECO_WIN32_GETOPT_H
#define ECO_WIN32_GETOPT_H

#include <cstdio>
#include <cstring>

#define no_argument       0
#define required_argument 1
#define optional_argument 2

struct option {
    const char* name;
    int         has_arg;
    int*        flag;
    int         val;
};

inline char* optarg = nullptr;
inline int   optind = 1;
inline int   opterr = 1;
inline int   optopt = '?';

namespace eco_getopt_detail {

inline int handle_short(int argc, char* const argv[], const char* shortopts,
                        char ch) {
    const char* p = std::strchr(shortopts, ch);
    if (!p || ch == ':') {
        if (opterr) std::fprintf(stderr, "%s: unknown option -%c\n", argv[0], ch);
        optopt = ch;
        return '?';
    }
    if (p[1] == ':') {
        // Requires an argument.
        if (optind >= argc) {
            if (opterr) std::fprintf(stderr, "%s: option -%c requires an argument\n",
                                     argv[0], ch);
            optopt = ch;
            return ':';
        }
        optarg = argv[optind++];
    } else {
        optarg = nullptr;
    }
    return ch;
}

}  // namespace eco_getopt_detail

inline int getopt(int argc, char* const argv[], const char* shortopts) {
    if (optind >= argc) return -1;
    char* arg = argv[optind];
    if (!arg || arg[0] != '-' || arg[1] == '\0') return -1;
    if (arg[1] == '-' && arg[2] == '\0') {
        ++optind;
        return -1;
    }
    optind++;
    return eco_getopt_detail::handle_short(argc, argv, shortopts, arg[1]);
}

inline int getopt_long(int argc, char* const argv[], const char* shortopts,
                       const struct option* longopts, int* longindex) {
    if (optind >= argc) return -1;
    char* arg = argv[optind];
    if (!arg || arg[0] != '-' || arg[1] == '\0') return -1;

    // Bare "--" → terminator.
    if (arg[1] == '-' && arg[2] == '\0') {
        ++optind;
        return -1;
    }

    // Long option: "--name" or "--name=value".
    if (arg[1] == '-') {
        const char* name = arg + 2;
        const char* eq   = std::strchr(name, '=');
        size_t nameLen = eq ? static_cast<size_t>(eq - name) : std::strlen(name);

        for (int i = 0; longopts[i].name; ++i) {
            if (std::strlen(longopts[i].name) == nameLen &&
                std::strncmp(longopts[i].name, name, nameLen) == 0) {
                ++optind;
                if (longindex) *longindex = i;
                if (longopts[i].has_arg == required_argument) {
                    if (eq) {
                        optarg = const_cast<char*>(eq + 1);
                    } else if (optind < argc) {
                        optarg = argv[optind++];
                    } else {
                        if (opterr)
                            std::fprintf(stderr, "%s: option --%s requires an argument\n",
                                         argv[0], longopts[i].name);
                        return '?';
                    }
                } else {
                    optarg = nullptr;
                }
                if (longopts[i].flag) {
                    *longopts[i].flag = longopts[i].val;
                    return 0;
                }
                return longopts[i].val;
            }
        }
        if (opterr) std::fprintf(stderr, "%s: unknown option --%.*s\n",
                                 argv[0], static_cast<int>(nameLen), name);
        ++optind;
        return '?';
    }

    // Short option.
    optind++;
    return eco_getopt_detail::handle_short(argc, argv, shortopts, arg[1]);
}

#endif  // ECO_WIN32_GETOPT_H
