# Build system

One CMake graph, run by Ninja and configured through named presets, builds every piece of Eco on Linux, macOS and Windows. The platforms share the graph, the targets and the core test gates, and differ only in what a self-contained release can mean on each. On Linux the shipped `eco` is fully static, carries its own linker and libraries, and needs nothing on the host. On macOS it links the system libraries dynamically and everything else statically. On Windows it links the system libraries dynamically and its C runtime statically, and it relies on Microsoft's build tools being installed to link the programs it compiles. Each platform has one continuous-integration (CI) workflow that runs the whole bootstrap and the test gates and ends by packaging that platform's bundle. A separate publisher takes only builds that passed on all three platforms and turns them into a nightly or a tagged release.

## One graph, set by presets

The top-level project owns the C++ runtime, the kernels, the MLIR dialect, the tests, the packaging and the convenience targets: the full rebuild with end-to-end tests, the quick check for C++-only changes, and the stress tests. The compiler subproject owns the Elm side and the nine-stage chain that [bootstrap.md](bootstrap.md) describes. Because both live in one graph, Ninja sees every dependency from an Elm source file through the native compiler to the packaged bundle, and one command can build any of them with exactly the work it needs.

Everything that varies between builds is a CMake option, and a preset is a saved set of option values with a name. The options cover a static link, a static link against musl, an archive-only build of the glibc runtime, a front-end-only configuration, the choice of linker, kernel tracing and a compiler cache. Keeping the variation in options means one set of targets serves every configuration. Linux has three presets, ordered by how much checking they keep:

| Configuration | Checking | Used for |
|---|---|---|
| Debug | full assertions, statistics, kernel tracing | chasing a bug |
| Optimized with debug information | assertions on | everyday work and the bootstrap |
| Release | assertions off, stripped, static musl | the shipped Linux bundle |

macOS and Windows each have a full preset and a front-end-only preset, and CMake offers each pair only on its own host. The front-end-only preset builds just the Node-hosted stages, which is how a port starts before LLVM builds there.

## Where the tools come from

Every tool the build runs is pinned, so a build is a function of the sources, the preset and the pins.

LLVM and MLIR are pinned to one release and built the same way, as static libraries, on all three platforms. The version appears in Docker image tags, workflows and presets, and a bump has to change all of them together. On Linux, LLVM and MLIR are built in two base images, one on Debian with glibc and one on Alpine with musl. A source build of LLVM takes 30 to 60 minutes and the pin changes rarely, so the base images are rebuilt only on a bump, and the images that use LLVM copy its finished install tree from them: a glibc development shell, a musl development shell and the static release build.

CMake downloads the Elm tools itself: the stock Elm compiler, the formatter and the test runner. Each download comes from the tool's upstream release, is checked against a SHA-256 hash recorded per platform, and is retried on failure. The npm packages for these tools are wrappers whose install scripts fetch the real binaries from third-party hosts, so a lockfile would pin only the wrapper. For the same reason the JavaScript package manager runs with install scripts disabled.

## What a bundle is on each platform

A bundle is `eco` plus the runtime archives and support files that compiled programs link against. The binary and its runtime tree are installed side by side, because `eco` finds its runtime by a path relative to its own executable. The bundle layout is therefore an interface with the native driver, and moving a directory in it means changing the driver too.

| | Linux | macOS | Windows |
|---|---|---|---|
| Compiler and linker for `eco` | clang, lld, libc++ on Alpine | clang, with the linker and SDK found through Xcode | clang-cl, lld-link |
| Linked statically | everything, including the C library | LLVM, OpenSSL | LLVM, the C runtime |
| Linked dynamically | nothing | the system library, libc++, libcurl, zlib | the system libraries |
| Needed on the user's machine | nothing | the operating system | Visual Studio Build Tools and the Windows SDK |

### Linux: one static binary

The Linux product is one binary that runs on any distribution and produces programs that run on any distribution, with no toolchain installed on the host. That requirement is why the release links against musl, a C library designed for static linking, and not against glibc, the C library most distributions use. The bundle carries a static copy of LLVM's linker, lld, along with the C startup objects and every archive a program needs, and the driver writes link lines with absolute paths into the bundle so it never searches the host.

Two linkers are in play on Linux, and which one links `eco` depends on the kind of executable. A glibc development build produces a position-independent executable (PIE), and lld refuses one kind of absolute relocation in the stack-map section when it produces a PIE. The stack maps are the tables the collector uses to find pointers on the stack, so they cannot be dropped, and the glibc build links with the GNU linker instead. The static musl release is not position-independent, so lld accepts the same relocations there. The linker is an option rather than fixed, so a build can return to the GNU linker if lld regresses.

The release is built inside Docker. A static build stage links `eco` against libc++, LLVM's compiler support library and LLVM's unwinder, then CMake's packager, CPack, packages the bundle as a tar archive, a zip file and a Debian package. The Debian package installs under `/usr/local` because Debian policy reserves `/usr` for distribution packages, and the archives hold the same files so all three formats agree. The last Docker stage installs the bundle and runs smoke tests against it.

### Linux: a second runtime set for shared libraries

`eco` can build executables, shared libraries and Node addons, and they need different C libraries. A shared library or an addon is loaded into a host process that already has its C library, so a static musl copy inside it would be a second C library in one process. An executable has no host process, and it must stay static, because linking it against the host's glibc brings back the dependence on the host and breaks musl distributions such as Alpine.

The bundle therefore carries two sets of runtime archives and picks one by output kind. Executables link against the musl set. Shared libraries and addons link against a glibc set that leaves the C library undefined, so the host process supplies it. The choice follows from the output kind and not from the user's machine, so it lives inside one bundle rather than in a separate glibc bundle the user would have to pick. Defaulting executables to dynamic glibc, or adding a switch for it, would bring back host coupling, and Eco does not offer either. The glibc set is built with libc++ like the rest of the bundle, and it keeps its symbols visible: hiding every symbol from the bundled libraries would also hide the entry points that Node and embedding hosts call.

A separate Debian stage builds the glibc set in an archive-only mode, and the static stage copies it into the bundle. A build-time audit then trial-links every staged archive as position-independent code and computes the oldest glibc version the set actually needs. The floor is computed rather than written down, so it stays true as the runtime changes.

### Linux: tuning that applies only to the bundle

Programs built by the musl bundle would run markedly slower than programs built in the development tree, because of musl's memory allocator and Alpine's default hardening flags. The release build makes three changes, and only the musl bundle gets them, because the other builds use their platform's own allocator and C library:

- stack protection and source fortification are turned off, and a configure check confirms it, since Alpine's compiler turns them on by default;
- a vendored mimalloc allocator is linked ahead of musl's C library;
- vendored LLVM libc versions of `memcpy`, `memmove`, `memset`, `memcmp` and `bcmp` are linked ahead of musl's C library.

Linking these as object files ahead of the static C library is what makes the override take precedence without pulling in musl's own versions. The five memory functions are replaced together because musl's `memmove` jumps into its `memcpy`, so replacing one alone still runs the other.

### macOS: static LLVM, dynamic system

The macOS build targets Apple Silicon with a fixed minimum OS version that matches the CI runner and covers every Apple Silicon Mac. The minimum is set before the project is declared, so every target inherits it. Eco builds LLVM and MLIR itself as static archives, and a CI workflow caches them. Homebrew's LLVM is built around a shared LLVM library that a shipped `eco` cannot rely on, its static MLIR archives still pull that library in through their CMake targets, and a stale or newer Homebrew would silently raise the OS floor.

The linker and SDK are found through Xcode's tool locator when a program is linked, not recorded when `eco` is built, because paths recorded at build time break on other Macs. The macOS workflow ends with a smoke test of the bundle on a clean runner and a check of the minimum OS version recorded in the binary.

### Windows: dynamic system, static C runtime

Windows guarantees a stable set of system libraries, so the static machinery of the Linux build has nothing to solve there. Eco links the C runtime statically, so users need no redistributable package. It builds with clang-cl, the Microsoft ABI and Ninja, which keeps the presets and target names the same as on the other platforms; a MinGW toolchain or the Visual Studio project generators would make Windows a build of its own. The bundle carries no linker, so users install the Visual Studio Build Tools and the Windows SDK. The project has no Windows machine, so the port is built and tested only through CI.

## Version numbers without a counter

One version file holds the version, and the build stamps it into the build tree. A checked-in baseline copy of the generated version module must match the version file, or configuration fails, so a compile outside CMake still reports the right version. Development builds append the commit hash. An override setting stamps the binary and the package file names with one string, so the two cannot disagree.

CI builds need a version that is unique, ordered and the same on every platform for the same commit, without any stored state. A short script derives it from git:

```bash
base=$(git show "$rev:version.txt" | tr -d '[:space:]')

if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
    if [ "${GITHUB_REF_NAME:-}" != "v$base" ]; then
        echo "::error::tag ... does not match version.txt (v$base)" >&2
        exit 1
    fi
    echo "$base"
    exit 0
fi

if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "::error::shallow clone: ..." >&2
    exit 1
fi
echo "${base}~b$(git rev-list --count "$rev").g$(git rev-parse --short=12 "$rev")"
```

From `.github/scripts/eco-version.sh`. The build number is the count of commits reachable from the revision, which every platform computes the same way, and a shallow clone is refused because it would count only one commit. The `~` sorts before the plain version in Debian ordering, so a nightly never outranks the release it leads to. A tag builds the plain version, and the tag has to equal the version file. GitHub rewrites `~` in release asset names, so the publisher replaces it in file names, and asset names differ slightly from the printed version.

## From a green build to a release

Each platform has one workflow, which runs the whole chain and the test gates and ends by building the bundle. The core gates are the same everywhere: the compiler's Elm tests, the main test executable and the whole chain. Only Linux adds the stress tests and the end-to-end tests of natively compiled programs, and on Windows the codegen and whole-program suites in the test executable run no tests. macOS and Windows have a single toolchain each, so splitting testing from shipping into separate workflows would only repeat the configure steps, and macOS runner minutes are billed at a premium. A set of separate bootstrap, runtime and ahead-of-time workflows per platform therefore does not exist.

The Linux workflow runs three parallel jobs inside that one workflow:

- a test job: the first end-to-end gate, the compiler's Elm tests and the stress tests;
- a bootstrap job: the nine-stage chain and the end-to-end tests of natively compiled programs;
- a bundle job: the static musl bundle.

Running them in parallel halves the time to a result. The bundle job does not wait for the gates, which is safe because the publisher takes only runs whose overall result is success. Eco ships the musl build but runs the bootstrap on the glibc build, the flavor used for development and testing, because the self-hosting chain runs reliably there.

No workflow builds LLVM. Each restores a prebuilt LLVM cache and fails if the cache is missing, because a cold cache would otherwise turn into a silent rebuild of more than an hour inside the run. Cache-warming workflows rebuild LLVM per platform on a schedule, and scheduled runs keep the caches in use, because GitHub evicts a cache left unused for seven days. The C++ compiler cache is saved only from the main branch, and a pruning script deletes superseded entries, because saving it on every commit can push the LLVM caches out of the storage limit.

Publishing is separate from building, because artifacts attached to a CI run need a login to download and expire. The nightly publisher picks the newest main-branch commit whose workflows passed on all three platforms, so every asset in the nightly shares one version. It stages the replacement release as a draft before swapping it in, so a failed swap cannot leave the project with no nightly. A release workflow waits for the three builds of a version tag and then publishes a stable release.

## Checks that run on every build

Some checks must run on every full rebuild and every quick check, not only when someone asks for them. The test directory is added to the graph but excluded from the default target, so a target defined there never runs in a default build. These checks are therefore defined in the top-level project:

- a license check on the kernel sources, which fails the build when the kernels drift from their manifest;
- a canary that notices when collector code described by the formal concurrency models changes without the models being reviewed, which warns by default and fails only when a build setting asks it to;
- scripts that check bounded roots and large-body access, and, for the full rebuild, where each kernel function is implemented.

The canary touches its stamp only after a clean check, so its warning repeats on every build until the check passes.

## Examples of changes that fit the theory
A change fits when it adds to a list the graph already iterates over, keeps a platform difference behind an existing option or preset, and holds every platform to the same gates.

- An added kernel or system module goes into the module lists in the runtime's code-generation build file. Archive targets, link lines and the bundle's install loops all iterate over those lists, so no other wiring is needed.
- A knob that changes only compile flags is an option plus a value in each preset, as with the compiler cache, frame pointers and kernel tracing.
- A bundle-only optimization goes under the static musl block, installs as a bundle file, gets a path constant in the runtime's boot configuration, and adds a smoke check. The allocator and memory-function replacements have this shape.
- Bumping a pinned tool changes the URL and hash in the toolchain file. Bumping LLVM changes the Dockerfiles, presets and workflows in one commit.
- Another platform gets an LLVM cache-warming workflow, one workflow with the shared gate order, a full and a front-end-only preset, and a bundle install section. Like the macOS and Windows ports, it starts front-end only.
- An extra CI gate is a step in every per-platform workflow. The publisher's rule that only fully successful runs are published covers it with no change.

## Examples of changes that would break the theory
- Recording a host or runner path in generated configuration. A path recorded at build time breaks on the next machine; resolve it at run time or link time, as the macOS linker lookup does.
- Defining the version in a second place, or letting a workflow compute its own build number. Platforms would then disagree on the version of one commit; extend the version script instead.
- Putting an always-run check in the test directory's build file. It never joins the default target; define it in the top-level project.
- Solving a musl-only problem by changing the path shared by development, macOS and Windows builds, or the reverse. The other builds have their own allocator and C library and would pay for a fix they do not need; gate the change on the static musl option.
- Making the bundle rely on host packages such as binutils, gcc or Homebrew to link programs. The bundle exists so that Linux needs no host toolchain and macOS needs only the operating system; add what is missing to the bundle.
- Letting a CI job build LLVM inline on a cold cache. Every run would carry an hour-long build that nobody sees; warm the cache with the warming workflow.
- Splitting a platform's workflow back into per-stage workflows, or making publishing a step of the build workflows. The first repeats configure work and the second publishes a platform's bundle before the other platforms have passed.

## References

Parent: [build-and-workflow.md](workflow.md). Sibling: [bootstrap.md](bootstrap.md).

- `CMakeLists.txt`: options (`ECO_STATIC`, `ECO_STATIC_MUSL`, `ECO_GLIBC_OUTPUT_RUNTIME`, `ECO_FRONTEND_ONLY`, `ECO_LINK_WITH_BFD`, `ECO_KERNEL_DEBUG`, `ECO_USE_CCACHE`, `ECO_FRAME_POINTERS`, `ECO_VERSION_OVERRIDE`, `ECO_TLA_CANARY_STRICT`), bundle install and CPack, convenience targets (`check`, `full`, `rebuild`, `stress`), the top-level checks (`kernel-license-check`, `tla-canary`, `check-root-bounded.py`, `check-large-body-access.sh`, `check-kernel-homes.sh`), the configure check on hardening flags.
- `CMakePresets.json`: `dev` (Debug), `build` (RelWithDebInfo), `release` (static musl), `mac-build`, `mac-frontend`, `win-build`, `win-frontend`.
- `compiler/CMakeLists.txt`: the Elm build, shadow roots and version stamping.
- `compiler/cmake/toolchain.cmake`: pinned downloads of `elm`, `elm-format` and `elm-test-rs` (`eco_fetch`).
- `version.txt`, `compiler/cmake/Version_Build.elm.in`, `compiler/src-version/`: version file, template and baseline.
- `.github/scripts/eco-version.sh`, `docker/build-dist.sh`: numbered builds.
- `docker/llvm-debian.Dockerfile`, `docker/llvm-alpine.Dockerfile`: LLVM and MLIR base images. `docker/static-build.Dockerfile`: the Linux release pipeline.
- `cmake/GlibcRuntimeAudit.cmake`, `cmake/glibc_floor.sh`: glibc set audit and floor (`GLIBC_FLOOR`). `cmake/LLVMLibunwind.cmake`: unwinder selection. `cmake/CPackProjectConfig.cmake`: package formats and prefix.
- `runtime/third_party/llvm-libc/` and its `README.md`, `eco_memfuncs.cpp`: vendored memory functions.
- `runtime/src/codegen/CMakeLists.txt`: module lists (`ECO_ELM_KERNEL_MODS`, `ECO_KERNEL_MODS`, `ECO_SYSTEM_MODS`). `runtime/src/codegen/EcoBootConfig.h`: runtime tree relative to the executable. The native driver's `LinkProfile`: archive set per output kind.
- `experiments/mac-llvm-build/build.sh`, `experiments/win-llvm-build/build.ps1`: per-platform LLVM builds (`ECO_MAC_DEPS_DIR`).
- `.github/workflows/linux-aot.yml`, `mac-aot.yml`, `win-aot.yml`: per-platform workflows. `mac-llvm-build.yml`, `win-llvm-build.yml`: cache warmers. `publish-nightly.yml`, `release.yml`: publishing. `.github/scripts/prune-caches.sh`: cache pruning.
- `docs/building.md`, `docs/building-macos.md`, `docs/building-windows.md`, `docs/build-targets.md`, `design_docs/distribution.md`, `design_docs/lld-in-eco.md`.
- `test/tla/README.md` "The canary": the canary's rule.

Known disagreements in the repository's documents: `design_docs/distribution.md` and some comments in `CMakeLists.txt` name a preset `ninja-clang-lld-linux-musl`, which is `release`. `design_docs/distribution.md` and `docs/build-targets.md` list 9 EcoKernel archives and no EcoSystem archives; the build has 11 and 12. `docs/building.md` speaks of three presets; there are seven. `docs/build-targets.md` omits the glibc-runtime, `eco-system-*`, `run-js-e2e`, `kernel-license-check` and `tla-check` targets.
