# Build and workflow

Eco is built by one CMake project in which every stage of the compiler's self-compiling chain is an ordinary build target, so building the shipped `eco` command and testing that the compiler can rebuild itself are the same act. The chain starts from the stock Elm compiler, moves the compiler from JavaScript to native code, and checks twice that the compiler reproduces itself exactly before it fuses the final binary. The same graph builds the runtime, the kernels and the tests, and produces one self-contained bundle per platform under one continuous-integration workflow per platform. Work on Eco follows the build: a change is written down as a plan, made in small steps, and judged by build targets and by measurements that change one thing at a time. Those habits exist because the system is large and slow to rebuild, and a mistake in it can easily go unnoticed.

## Building Eco means watching it compile itself

The compiler is a large Elm program that allocates heavily, so compiling it with itself exercises the front end, the back end, the runtime and the kernels at once. Eco uses that as its broadest test. A back-end regression usually shows up as a crash or a mismatch somewhere in the self-compile, even when no small test covers the feature that broke, so the chain is the cheapest place to catch it.

The chain's checks are fixed points. A compiler compiles its own source, the result compiles the same source again, and the two outputs must be identical byte for byte. If they are, the compiler that was just built behaves, on the largest program available, exactly like the compiler that built it. Eco checks one fixed point for the JavaScript compiler and one for the native compiler, which is what shows that the native compiler behaves like the JavaScript one.

These checks are only worth anything if nothing can skip them, which is why the chain lives inside CMake rather than in a script beside it. Each stage is a target with declared inputs and outputs, and each check writes a stamp file that the next stage depends on. CMake therefore knows the stage order, reruns only the stages whose inputs changed, and builds every predecessor of whatever is asked for. Asking for `eco` means passing every check on the way, and a failed check stops the build before anything downstream of it runs.

## The three parts

This area has three parts. The first two are the machinery, from the whole graph down to its longest path. The third is how people and agents use that machinery.

The build system is one CMake graph, driven by named configurations called presets, that builds every piece on every platform. A top-level project builds the C++ runtime, the kernels, the MLIR dialect and the tests, and it includes the compiler as a subproject that owns everything on the Elm side. Platforms differ only in what a self-contained release can mean. On Linux it is a fully static bundle built against musl, a C library designed for static linking. On macOS and Windows the bundle links system-provided libraries dynamically and everything else statically. Continuous integration runs one workflow per platform that goes through the whole chain and the test gates and ends in that platform's bundle, and a separate publisher promotes bundles that passed to a nightly build or a tagged release. See [build-system.md](build-system.md).

The bootstrap carries the compiler from the stock Elm binary, its only trusted ancestor, to one self-contained `eco` binary. It is a chain of nine stages through two JavaScript generations, a native generation and the final fused binary. Each step either changes the host the compiler runs on or checks that the compiler reproduces itself, so the chain ends only after a fixed point has been seen on both hosts. See [bootstrap.md](bootstrap.md).

Development practice is the loop of measure, plan, implement and measure again. A plan states a hypothesis and the conditions it must meet. A benchmark protocol fixes the workload and the method. A guide turns the loop into a prompt that an agent can repeat. Diagnostic tools for heap profiles, collector timing and memory supply the numbers, and results flow back into the plan and into the code's comments and numbered rules. The plan's text, not its status line, holds the reasoning. See [development-practice.md](development-practice.md).

The three meet at the build targets. The bootstrap is the longest dependency chain in the build system's graph. The development loops use build targets as their judge of success: the full rebuild with end-to-end tests (`full`), the complete chain (`bootstrap`), the compiler's Elm test suite (`elm-tests`), and a quick relink for changes that touch only C++. Changes to the build and to the chain are argued in plans before they land.

## The chain at low resolution

The stages run in this order, and building any stage builds the ones before it.

| Stage | Host running the compiler | What happens | Why |
|-------|---------------------------|--------------|-----|
| 1 | Stock Elm | Builds a JavaScript compiler whose file and process access goes through a browser-style request layer | Stock Elm cannot compile Eco's kernel-based IO code |
| 2 | JavaScript | That compiler compiles itself with kernel-based IO | Leaves stock Elm behind |
| 3, 4 | JavaScript | Two more rounds, compared byte for byte | The JavaScript fixed point |
| 5 | JavaScript | Emits MLIR for itself with a lighter specialization engine | The first native compiler's input, within Node's memory |
| 6 | C++ back end | Lowers that MLIR to a native compiler | The first native host |
| 7 | Native | Emits itself again with the default optimizing configuration, which is lowered again | Everything shipped comes from optimized code |
| 8 | Native | A second native round, compared byte for byte | The native fixed point |
| 9 | Native | Fuses the front end and the back end into `eco`, which then compiles itself once | The shipped command, shown to work |

Two end-to-end test gates sit early in the chain, one after stage 1 and one after the JavaScript fixed point. Each self-compile costs tens of minutes, so a back-end failure should be reported at the cheap stage where it first appears, not after an hour of native rounds. The gates are separate targets that hold this place only in the documented order of work; the aggregate chain target does not run them.

Three stages break the pattern, and [bootstrap.md](bootstrap.md) gives the reasons in full. Stage 1 alone uses a request-based IO layer and is built unoptimized, because stock Elm cannot compile the kernel-based one. Stage 5 uses a lighter specialization engine so that a Node-hosted self-compile fits in memory, and nothing shipped comes from it; the shipped `eco` is built from the stage-7 MLIR, whose lowering passed the stage-8 fixed point. Stage 9 checks that `eco` can compile itself but makes no byte comparison, because only `eco` embeds the back end.

A change to C++ alone does not change the MLIR the compiler emits for itself, because that MLIR is decided by the compiler's Elm sources; the C++ code only lowers it and runs it. A quick relink target uses this to rebuild `eco` from the stage-7 MLIR already on disk without rerunning the chain. It skips the stage-8 gate, so it is a convenience for local development, and it works only after a full bootstrap has produced that MLIR.

## Keeping every build reproducible

Three choices keep a build a function of its sources, its preset and its pinned tools, and keep the source tree untouched by it.

All build products live under the CMake build directory, in shadow project roots whose source files are links back into the repository. The source tree stays clean, deleting the build directory is a full reset, and each preset keeps its own bootstrap cache. Separate caches matter because builds with different assertion settings can legitimately emit different MLIR, and a rebuilt compiler that reads a stale cache crashes the chain at stage 2. The compiler needs no change for any of this, since it finds its project file by walking up from the working directory. For the same reasons Eco has no build directories inside the source tree and no per-configuration project files at the compiler root.

CMake downloads the Elm toolchain binaries itself and checks each against a pinned hash, because the npm packages for them are wrappers whose lockfile would pin only the wrapper and never the binary that runs ([build-system.md](build-system.md)).

One version file is the single source of the version string, and the build stamps it into the build tree rather than rewriting a tracked file; [build-system.md](build-system.md) describes the stamping and the CI build numbers.

## One bundle and one workflow per platform

Every platform runs the same core gates and ships one self-contained bundle, and the build environment is arranged so that this stays affordable. There are two exceptions: only Linux runs the stress tests and the end-to-end tests of natively compiled programs, and on Windows the in-process codegen and whole-program suites run no tests.

The development environment is a Docker image, and LLVM and MLIR are built in separate base images that are rebuilt only when the pinned LLVM version changes, because an LLVM build is slow and the version changes rarely. On Linux the shipped binary comes from the static musl image, so one `eco` runs on any Linux distribution, while a glibc image is used for testing and development ([build-system.md](build-system.md)).

Each platform has one continuous-integration workflow that runs the whole chain and that platform's test gates and ends by building the bundle. Eco does not split a platform's work into a set of separate workflows for the bootstrap, the runtime and ahead-of-time compilation. macOS and Windows each have a single toolchain, so such a split would only repeat configure steps and spend runner time, which is billed at a premium on macOS. The single workflow does not build LLVM itself. Scheduled cache-warming workflows keep the LLVM builds cached, so the per-platform workflow restores them instead.

Publishing is decoupled from building. Artifacts attached to a CI run need a login to download and expire after a while. A separate publisher therefore takes the newest commit whose builds passed on all three platforms and moves one nightly tag to it, and a stable release is published from a version tag once that tag's three builds pass.

A port starts with the front end. A platform without a working LLVM build can configure only the compiler subproject, which runs the stages that need nothing but Node and Elm. The native back end joins once LLVM builds on that platform, and the macOS and Windows ports have presets for both steps.

## Working on a large, slow system

Eco's working habits answer one problem: a single rebuild is slow, a mistake can hide in it, and much of the work is done by agents running unattended. Four habits follow, in the order a change meets them.

A change is written down before or while it is built. A plan states the goal, the current state as checked in the code rather than assumed, a table of decisions, and how each review comment was resolved. An agent or a newcomer can then see what was intended and which options were turned down. The plan is where a change is argued. The reasons that must last go into the rule catalog, the code comments and the commit message, because that is where readers look for them.

Optimization work changes one thing per measured iteration. Compile-time and collector tuning have noisy effects that interact, so a single step with several changes cannot say which one helped. The loops fix the workload, keep a reference row that is always the best result so far, and revert a step that loses. Losing steps stay in the table, so nobody tries them again blind.

Guides written as prompts let an agent run a fix loop unattended: pick one failure, diagnose it, fix it, record it, repeat. Separate loops cover failing tests, a broken bootstrap, profiling, memory, stack depth and dead code. The work is long, the failure lists are long, and the development machine is small, so the guides fix the order of operations and the resource limits. One self-compiling Node process needs a 16 GB heap, so a 16 GB machine runs one at a time, and a test run happens once with its output saved and read afterward. A profiling run that crashes is reported and stopped, rather than turned into a debugging session.

Commit subjects are specific, imperative and written in the codebase's own vocabulary, because the history is searched for the reason behind a line of code.

## Preconditions of the build

The build works only while four conditions hold. They are listed from the machine inward.

- A Docker image, or a host with the pinned LLVM and MLIR version, Node, pnpm, Python 3 and GNU time, plus network access at configure time so the pinned toolchain can be fetched.
- Node with a 16 GB heap and a large stack for the self-compiling stages. The build sets both itself, so manual settings in some guides are only a fallback.
- A compiler that stays self-hosting in both its JavaScript and native forms. Any language feature the compiler uses must work at every stage.
- The numbered rule catalog for code generation and runtime work. No build step reads it; the tests enforce it.

## Examples of changes that fit the theory
A change fits when it adds to the graph CMake already tracks, keeps every platform on the shared gates, and keeps every product inside the build directory.

- A kernel library or runtime source joins the existing library lists, and stages 6 to 9 link it without further wiring.
- Another platform is a pair of presets (full and front-end only), a row of pinned toolchain hashes, an LLVM cache-warming workflow and a per-platform workflow with the shared gate order. It starts front-end only, like the macOS and Windows ports.
- An optional diagnostic is a CMake option whose default each preset sets, as heap validation, collector phase timers and kernel tracing are.
- A measured optimization effort is a plan, then a benchmark protocol with a fixed workload, a reference row and a script that snapshots the results.
- An extra test gate is a build target that every per-platform workflow calls, at the point in the chain where it fails cheapest.

## Examples of changes that would break the theory
- Adding a stage as a shell script outside CMake, or as a target without declared inputs and stamp dependencies. CMake would stop tracking stage order and reruns, and the build could run past a check. Make it a custom target that depends on the previous stage's stamp.
- Writing build products into the source tree, or hard-coding paths outside the build directory. Clean resets and per-preset bootstrap caches both depend on the build directory holding everything. Put outputs under the binary directory and link back to sources.
- Weakening a fixed-point check, or building a shipped `eco` without passing the stage-8 gate, to get past a regression. The shipped binary would then carry code that was never shown to reproduce itself. Fix the regression; keep the quick relink for local work after a full bootstrap.
- Fetching tools through package install scripts or an ad hoc download. That reopens the gap pinning closes, where the binary that runs is not the one the lockfile names. Add a pinned, hash-checked fetch to the toolchain file.
- Giving one platform's workflow a test gate that the others could run. A failure would then show on one platform only, and the platforms would drift apart unnoticed. Add the gate to every workflow that can run it; the stress tests and the native end-to-end runner, which run only on Linux, are the existing exceptions.
- Letting CI build LLVM inline when its cache is cold. That makes a slow LLVM build part of every run. Warm the cache with the cache-warming workflow.
- Recording a performance claim in a plan or guide without a loop-style protocol behind it. Noisy, interacting effects make a one-off number unreliable. Give it a fixed input and a reference row.

## References

Parent: [eco.md](../../../THEORY.md). Children: [build-system.md](build-system.md), [bootstrap.md](bootstrap.md), [development-practice.md](development-practice.md).

- `CMakeLists.txt`, `CMakePresets.json`: the top-level graph, its options (`ECO_HEAP_VALIDATE`, `ECO_GC_PHASE_TIMERS`, `ECO_KERNEL_DEBUG`, `ECO_FRONTEND_ONLY`) and the presets (`build`, `dev`, `release`, and the `mac-*` and `win-*` pairs).
- `compiler/CMakeLists.txt`, `compiler/cmake/bootstrap/`, `docs/bootstrap.md`: the stage targets and their stamps, best read together. `bootstrap` is the aggregate target and `eco-quick` the C++-only relink. Stage 5 uses the `subst` specialization engine; stages 7 and 9 use the solver engine with lambda-set specialization. The comment above `ECO_STAGE9_2_OUTPUT` explains the absent stage-9 byte comparison.
- `compiler/cmake/toolchain.cmake`: pinned toolchain downloads.
- `version.txt`, `compiler/cmake/Version_Build.elm.in`, `compiler/src-version/`: version stamping.
- `docs/building.md`, `docs/build-targets.md`, `docker/`: build environments and targets, including `full`, `elm-tests` and the kernel library lists.
- `.github/workflows/`: the per-platform `*-aot` workflows (start with `linux-aot.yml`), the `*-llvm-build` cache warmers, `publish-nightly.yml` and `release.yml`.
- `plans/`, `compiler/plans/`: plans, for example `plans/consolidate-ci-build-workflows.md` and `plans/cmake-output-relocation.md`.
- `benchmarks/*-opt-loop.md`: measured optimization protocols, for example `benchmarks/fe-opt-loop.md`.
- `guides/*-loop.md`, `guides/*-howto.md`, `guides/*-hints.md`: agent loops and diagnostic recipes, for example `guides/test-fix-loop.md` and `guides/prof-hints.md`.
- `heap-profile.py`: heap profiling.
- `GITSTYLE.md`: commit message rules.
- `design_docs/invariants.csv`: the rule catalog the tests enforce.

Known disagreements in the repository's own documents. `docs/bootstrap.md` and `guides/bootstrap.md` suggest a 12000 MB Node heap; the CMake recipes set 16384 MB, and the recipes are right. `guides/bootstrap-fix-loop.md` speaks of eight stages; there are nine. `plans/release-bundle-v0.1.0.md` says stage 9b proves a byte-identical rebuild; it deliberately does not.
