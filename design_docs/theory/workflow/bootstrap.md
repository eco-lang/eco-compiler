# Bootstrap

The Eco compiler is an Elm program, and before the chain runs the only thing that can compile Elm is the stock Elm compiler, which emits JavaScript. The bootstrap is a chain of nine CMake stages that carries the compiler from that stock binary, its only trusted ancestor, to one self-contained native `eco` binary. The first generations run as JavaScript on Node and swap in Eco's own input and output layer. A JavaScript generation then emits the compiler as MLIR, the C++ back end lowers that MLIR into the first native compiler, and the native compiler rebuilds itself with the compiler's default, heavier specialization. Each stage either moves the compiler to a different host or checks that it reproduces itself exactly, once on JavaScript and once natively. Only after both checks pass does the last stage fuse the native front end with the back end into `eco`.

## Why the chain starts from JavaScript

Nothing but stock Elm can compile the compiler's source before the chain runs, and stock Elm produces only JavaScript. Every part of Eco that emits MLIR is itself Elm source, so the first MLIR the compiler ever produces has to come from a compiler running as JavaScript on Node. That MLIR is what the C++ back end turns into the first native compiler. From stage 6 on, the chain needs neither Node nor stock Elm, and a native compiler builds every later generation.

Starting from stock Elm also fixes what the chain has to trust. The stock binary is downloaded at a pinned version and checked against a recorded hash, and every later compiler is built from source by the one before it. No prebuilt Eco compiler is checked in and fed back into the chain.

## Stages, files and ordering

Each stage is a CMake custom command with declared inputs and outputs, and each check writes a stamp file that the next stage depends on. Building any stage therefore builds every stage before it, and a stage reruns only when its inputs change. The inputs include globs over the compiler's Elm sources and kernel sources, so adding a file reruns the chain with no CMake edit. The chain works in shadow project roots under the build directory, assembled from templates in the source tree, and never writes to the source tree.

The order in which files are produced, and which file feeds which stage, carries most of the design:

```text
1   guida.js                  = stock elm make  (HTTP-based IO, unoptimized)
2   eco-boot.js               = guida.js builds the compiler  (kernel IO, optimized)
3   eco-boot-2.js             = eco-boot.js builds the compiler
4a  eco-boot-3.js             = eco-boot-2.js builds the compiler
4b  require eco-boot-2.js == eco-boot-3.js                  # JavaScript fixed point
5   eco-compiler.mlir         = eco-boot-2.js emits the compiler, light engine   (waits for 4b)
6   eco-compiler              = native back end lowers eco-compiler.mlir
7a  eco-compiler-boot.mlir    = eco-compiler emits the compiler, default engine
7b  eco-compiler-boot         = native back end lowers eco-compiler-boot.mlir
8a  eco-compiler-boot-2.mlir  = eco-compiler-boot emits the compiler
8b  eco-compiler-boot-2       = native back end lowers eco-compiler-boot-2.mlir
8c  Linux:          require eco-compiler-boot == eco-compiler-boot-2
    macOS, Windows: require eco-compiler-boot.mlir == eco-compiler-boot-2.mlir
9a  eco-stage9.o              = native back end compiles eco-compiler-boot.mlir   (waits for 8c)
9b  eco = link eco-stage9.o with the back end;  eco builds the compiler once
```

Checked against `compiler/CMakeLists.txt`. Every comparison is byte for byte. Notice that stages 5 and 7a compile the same source on different hosts with different specialization engines, and that the stage-7a MLIR, not the stage-5 MLIR, feeds both the native fixed point and the shipped `eco`. The two "waits for" edges are explicit dependencies on check stamps. Without them, Ninja could start the next phase while a check is still running or after it has failed.

## Two input and output layers: stages 1 and 2

The compiler reads files, writes to the console and reports crashes through a small set of Eco modules, such as the file, console and crash modules. Two source trees supply those modules under the same names, and the difference between them is why stages 1 and 2 are separate.

Kernel code is the JavaScript or C++ that implements functions Elm itself cannot express, such as reading a file. Stock Elm links kernel code only from the Elm project's own packages, so a compiler built by stock Elm cannot touch the file system through kernels. The first tree works around that by expressing all input and output in plain Elm, as HTTP requests that a small Node server answers. The second tree implements the same modules as kernel functions: JavaScript kernels in the JavaScript stages and C++ kernels in the native stages.

Stage 1 builds the compiler with the HTTP-based tree. Stage 2 has that compiler build the compiler again with the kernel tree, and from then on no stage needs the Node server. Two compiler features exist for this hop: building a program whose kernel code belongs to an author other than the Elm project, and resolving a package from a directory on disk instead of the package registry.

Stage 1 is the only stage built without optimization. The HTTP-based crash function is Elm's placeholder for unfinished code, and Elm's optimizing mode forbids that placeholder. The kernel crash function has no such restriction, so stage 2 turns optimization on. A crash function written as an endless self-call would compile under optimization, but its generated JavaScript would need patching to behave, and dropping optimization in one throwaway stage costs less than maintaining a patch.

Every generated JavaScript file passes through exactly one post-processing script. It replaces the generated code that builds a string while reading bytes, because that code uses too much of V8's memory during a self-compile.

## The two fixed points

A fixed-point check has a compiler build its own source and compares the result with the compiler that did the building. If the two are identical, the compiler's output no longer depends on which compiler produced it. The chain makes the check once per host because each host exposes a different family of failures.

The JavaScript fixed point, at stage 4, covers the front end: parsing, type checking, optimization and code generation, as written in Elm. It compares the outputs of stages 3 and 4. Stage 5 starts only after it passes, so no MLIR is produced by a JavaScript compiler that has not reproduced itself.

The native fixed point, at stage 8, covers what the JavaScript check cannot see: the MLIR generator, the lowering passes, the runtime, the garbage collector and the C++ kernels. The bootstrap's own failure log shows this check catching bugs the JavaScript one cannot, such as stale pointers left by the lowering that rewrites calls so the collector can find roots, and heap corruption in byte encoding. On Linux the stage compares the two executables. On macOS and Windows the linkers embed timestamps or content-derived identifiers, so the stage compares the two MLIR bytecode files instead, which states the same fact without depending on the linker.

Both checks require every step to be deterministic: the compiler, its MLIR output and, on Linux, the linker must produce the same bytes from the same input. The MLIR compared is bytecode, the compiler's default output format, so the check covers the format that production builds use. Text output exists only as a debugging option.

## Which engine runs where

Specialization turns each polymorphic function into separate copies for the concrete types it is used at. The default engine, a solver with lambda-set specialization, produces the best code but is heavy: a Node-hosted self-compile with it needs about the whole V8 heap and may not finish. Stage 5's only job is a correct first native compiler, so it uses a lighter engine that fits in Node. Its MLIR builds stage 6 and nothing else.

Stage 5 also deletes the cached typed module files that specialization reads. The JavaScript stages neither write nor invalidate those caches, and a stale one crashes specialization.

Stage 7 runs on the native host, where Node's heap limit does not apply, so it emits the compiler again with the default engine. That MLIR is the one that ships. Stage 9 builds `eco` from it, and not from the stage-5 MLIR, because the compiler lowered from it is the one that stage 8 shows to reproduce itself.

## Stage 9: one binary, checked by use

Before stage 9, compiling a program takes two tools: the native compiler, which emits MLIR, and a separate native back end, which lowers MLIR to an executable. Stage 9 fuses them into one `eco` binary so a user installs one tool, and it starts only after stage 8 has passed.

Stage 9 then has `eco` compile the compiler once, and it succeeds if that compile works. It does not compare `eco` with the result. Only `eco` embeds the LLVM and MLIR back end, so `eco` and any binary it produces differ by construction, and a byte comparison could never pass. The native fixed point is checked at stage 8 instead, on compilers that do not embed the back end. On a glibc build the chain's executables are linked with the GNU linker, because lld refuses the stack-map relocations in a position-independent executable; [build-system.md](build-system.md) gives the full rule for which linker links what.

A quick relink target rebuilds `eco` from the stage-7 MLIR already on disk when only C++ has changed. The C++ code lowers and runs that MLIR but does not decide its contents, so the MLIR is still valid. The relink skips the stage-8 gate, so it serves local development and needs a full bootstrap to have run first.

## Test gates inside the chain

Two end-to-end test gates sit at the earliest stages that can run them. The gate after stage 1 runs the just-in-time suite, which needs only the first JavaScript compiler. The gate after stages 3 and 4 runs the ahead-of-time suite, which needs only the stage-3 compiler and the native back end. Each self-compile takes tens of minutes, so when the stages are run in the documented order, a back-end regression is reported before the expensive native rounds start, and is pinned to a few stages. The gates are separate targets rather than stamp dependencies: the aggregate `bootstrap` target does not run them, and continuous integration runs the ahead-of-time gate after the whole chain.

The full chain and the `eco` target are opt-in. Default and end-to-end builds stop at stage 1 or 2, and the final target is left out of the default build because its dependencies are the whole chain.

## What the chain relies on

The chain needs five things from outside itself, listed from the toolchain inward.

- A pinned stock Elm 0.19.1 binary, and a Node whose heap is large enough for a self-compile. Every Node-hosted stage sets a 16 GB heap itself, because a self-compile on Node needs nearly that much.
- Determinism of the compiler, its MLIR bytecode and, on Linux, the linker, as the fixed-point checks require.
- The kernel contract: each kernel function exists twice, in JavaScript and in C++, with the same behavior, because the JavaScript and native stages differ only in host.
- The parts it exercises: the native back end, the runtime and its collector, and the compiler's MLIR generation. A bootstrap failure is most often in one of these, not in the chain.
- The heap settings the self-compiling stages run with. They bound the memory those stages need and come from measured collector tuning.

A configuration that builds only stages 1 to 5 lets a platform without a working LLVM build bootstrap its front end.

## Examples of changes that fit the theory
A change fits when every stage can still rebuild it from source and both fixed points still hold at full strength.

- Adding an Elm source file or a kernel function. The stage inputs are globs, so the chain reruns itself. An added kernel function needs both its JavaScript and its C++ implementation, or the native stages diverge from the JavaScript ones.
- Adding an input or output capability the compiler needs. It goes into both layers and into the Node server's handler, so that stage 1 and stage 2 both still work.
- Adding a test gate or check at the earliest stage that can run it, where both existing gates sit.
- Tuning memory for one stage: its heap settings, its Node heap or stage 5's engine. Each is local to one custom command.
- Porting to a platform whose linker is not deterministic, by comparing the MLIR as macOS and Windows do.

## Examples of changes that would break the theory
- Making a later stage depend on output from a JavaScript stage that the native chain cannot reproduce. The shipped compiler would then carry something no fixed point has checked; feed later stages only from outputs that passed a check.
- Adding a byte comparison between `eco` and any ordinary binary. It can never pass; compare compilers that do not embed the back end, as stage 8 does.
- Shipping or testing against the stage-5 MLIR. It comes from the lighter engine and from a compiler that has not passed the native fixed point; use the stage-7 MLIR.
- Editing generated JavaScript beyond the one post-processing script, or adding Node-only behavior to a native stage. The native stages would stop matching the JavaScript ones; make the change in the kernel or the compiler.
- Weakening a fixed-point check to get a bootstrap through. A failing check means a real nondeterminism or miscompile; find it, as the bootstrap repair loop does.
- Changing the stand-alone bootstrap scripts to change the chain. CMake does not run them, and they differ from the CMake recipes; change the custom commands.

## References

Parent: [build-and-workflow.md](workflow.md). Sibling: [build-system.md](build-system.md).

- `compiler/CMakeLists.txt`: every stage as a custom command, with its comments, the `compare_files` checks in stages 4b and 8c, the stamp dependencies (`ECO_BOOT_VERIFY_STAMP`, `BOOTSTRAP_STAMP`), the source globs (`ELM_SOURCES`, `KERNEL_SOURCES`), and the `bootstrap`, `eco`, `eco-verify` and `eco-quick` targets. It labels stages 1 to 3 as steps. Treat it as the truth where documents disagree.
- `compiler/cmake/bootstrap/`: the `build-xhr` and `build-kernel` shadow roots, and `build-kernel/heap-config.json`.
- `compiler/cmake/toolchain.cmake`: the pinned stock `elm` binary.
- `compiler/src-xhr/Eco/` and `eco-kernel-cpp/src/Eco/`: the HTTP-based and kernel-based layers. `eco-kernel-cpp/src/Eco/Kernel/*.js` and `eco-kernel-cpp/src/eco-kernel/*.cpp`: the paired kernels.
- `compiler/bin/index.js`, `compiler/bin/eco-io-handler.js`: the Node server for stage 1.
- `compiler/scripts/replacements.js`: post-processing of generated JavaScript (`_Bytes_read_string`).
- `compiler/scripts/build-self.sh`, `compiler/scripts/build-verify.sh`: stand-alone scripts that CMake does not use.
- `compiler/lib/`, `compiler/scripts/build.sh`: committed bundles of the npm interface inherited from Guida, the compiler Eco's front end is forked from. They are not part of the chain.
- `runtime/src/codegen/`: the native back end (`eco-boot-native`) used from stage 6.
- `ECO_FRONTEND_ONLY`: the stages 1 to 5 configuration. `ECO_MONO_ENGINE=subst`: the light engine in stage 5. `--kernel-package`, `--local-package`: the stage 2 compiler options. `--text-mlir`: text MLIR output.
- `docs/bootstrap.md`: stage narrative and test gates. `guides/bootstrap.md`, `guides/bootstrap-fix-loop.md`, `guides/bootstrap-fails.md`: running the chain, the repair loop and recorded failures.

Known disagreements in the repository's documents: `docs/bootstrap.md` and `guides/bootstrap.md` say stock Elm comes from npm, but the build fetches a pinned binary, and they suggest a 12000 MB Node heap where the recipes set 16384 MB. `guides/bootstrap-fix-loop.md` speaks of eight stages; there are nine.
