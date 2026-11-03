---
status: not-started
updated: 2026-11-03
---

# Reorganize the compiler source tree: one folder per pass, no folder cycles

The compiler's modules have no import cycles, as Elm requires, but its folders do.
`compiler/src` has six folder cycles, and the passes of the middle end are spread
over `Monomorphize/`, `MonoSolver/` and `GlobalOpt/` in a way that hides their order.
This plan moves the source into a tree where each pass has its own folder, the
passes are in pipeline order, no pass imports a later one, and no two sibling
folders depend on each other. It lists every file move.

Most of the work is mechanical renaming. Four modules are split and two get small
edits; those come first, in step 1.

## Rules for the new tree

1. **Each pass has its own folder** directly under `Compiler/`: `Parse`,
   `Canonicalize`, `Type`, `Nitpick`, `LocalOpt`, then either `GenerateJs` (the
   erased branch) or `PreMono`, `Monomorphize`, `MonoOpt`, `GenerateMlir` (the typed
   branch).
2. **Passes are in order and never import a later pass.** A pass may import any
   earlier pass and any shared folder.
3. **The two branches are separate.** `GenerateJs` imports nothing from the typed
   branch, and the typed branch imports nothing from `GenerateJs`. They no longer
   share a `Generate/` folder.
4. **No folder cycles.** A folder contains everything beneath it: for `A/B/C.elm`,
   `A` contains `B` and `C`, and `B` contains `C`. At every folder, each child
   (a subfolder or a module file) is a node, and a child depends on a sibling when
   any module inside it imports any module inside the sibling. No two siblings may
   depend on each other, directly or around a loop. This must also hold under the
   stricter reading where `Foo.elm` counts as part of the folder `Foo/` next to it.
5. **Shared foundations sit below the passes**, in layers that only import
   downwards: `Core`, `Lexer`, `Json`, `Config`, `Elm`, `IR`, `Reporting`.
6. **Generic libraries know nothing of the compiler.** `Data/`, `Utils/`,
   `System/`, `Text/`, `Control/`, `Prelude` and `Mlir/` import no `Compiler.*` or
   `Builder.*` module.

## Where things stand (at `ac0896c0`)

### Folder cycles

`check-folder-cycles.py` (appendix A) finds six:

| Folder | Children in the cycle | Edges that close it |
|---|---|---|
| `./` | `Builder`, `Compiler`, `Data`, `Mlir`, `Prelude.elm`, `System`, `Text`, `Utils` | `Data.IORef`, `Data.Vector` and `System.TypeCheck.IO` import `Compiler.AST.*`; `Utils.Bytes.*` and `Utils.Main` import `Compiler.Data.*` and `Compiler.Reporting.Result`; `Compiler.Reporting.Error` imports `Builder.File`; `Mlir.Bytecode.VarInt` imports `Compiler.Data.Int64`; every library imports `Utils.Crash` while `Utils.Main` imports them |
| `Compiler/` | `AST`, `Data`, `Elm`, `Json`, `Nitpick`, `Parse`, `Reporting`, `Type` | each pass imports its own error module from `Reporting/Error/`, which imports the pass back (`Reporting.Error.Type` → `Type.Error`, `Reporting.Error.Pattern` → `Nitpick.PatternMatches`); `AST` imports `Reporting.Annotation`, `Elm.ModuleName` and `Elm.Kernel`; `Elm.Package`, `Elm.ModuleName`, `Elm.Version` and `Json.Decode` import `Parse.Primitives`, `Parse.Variable` and `Parse.Keyword` |
| `Compiler/AST/` | `Canonical.elm`, `Source.elm`, `Utils` | `Utils.Type` → `Canonical` → `Utils.Binop` |
| `Compiler/Canonicalize/` | `Environment`, `Type.elm` | `Environment.Local` → `Type` → `Environment.Dups` |
| `Compiler/Generate/` | `JavaScript`, `Mode.elm` | `Mode` → `JavaScript.Name`; `JavaScript.Expression` → `Mode` |
| `Builder/` | `Deps`, `Elm` | `Deps.Solver` → `Elm.Outline`; `Elm.Details` → `Deps.Registry`, `Deps.Solver`, `Deps.Website` |

### Forward dependencies in the middle end

The middle end has no folder cycles, but when it is cut into the passes that
`Compiler.Pipeline.Steps` runs (prepare and pre-mono, monomorphize, post-mono
inlining and global optimization, MLIR generation), several modules import a later
pass:

| Edge | Problem |
|---|---|
| `GlobalOpt.PreMono.AliasForward`, `EtaExpand`, `Fresh` and `GlobalOpt.InlineSimplify` → `Monomorphize.AssignMVarIds`, `Monomorphize.EntryPrep` | pre-mono imports mono; `EntryPrep` and `AssignMVarIds` are the prepare step and belong to pre-mono |
| `GlobalOpt.PreMono.AliasForward` → `Monomorphize.KernelAbi` | pre-mono imports mono, for two constant tables |
| `GlobalOpt.PreMono.EtaExpand`, `MonoSolver.Translate` → `GlobalOpt.KernelFacts` | pre-mono and mono import mono-opt; `KernelFacts` imports nothing |
| `GlobalOpt.InlineSimplify` sits in `GlobalOpt/` | it is the pre-mono inliner and works on the typed graph |
| `Generate.MLIR.Backend`, `Generate.MLIR.Context` → `Generate.Mode` → `Generate.JavaScript.Name` | MLIR generation depends on the JavaScript branch, for a `Mode` it stores and never reads |

## Target tree

`compiler/src/`, bottom layer first; each folder imports only folders above it in
this listing. `←` gives a moved module's current name (without `Compiler.` inside
`Compiler/`).

```
── Generic libraries ──
System/                Exit, IO, Console/Ansi
    Crash              ← Utils.Crash
Data/                  HashMap, Map, Set
    Bag, BitSet, Int64, NonEmptyList, OneOrMore   ← Compiler.Data.*
    Graph              ← Compiler.Graph
    Map/Utils          ← Compiler.Data.Map.Utils
Utils/                 Main, Bytes/{Decode,Encode}, Task/Extra
Text/PrettyPrint/ANSI/Leijen, Control/Loop, Prelude, Codec/Archive/Zip
Mlir/                  (unchanged)

── Compiler/: shared foundations ──
Core/                  identities and positions
    Name, Index, IndexName, Id        ← Data.*
    TypeIds            ← AST.TypeIds
    Annotation         ← Reporting.Annotation
    Snippet            ← AST.Snippet
    StringTable        ← AST.StringTable
    Suggest            ← Reporting.Suggest
Lexer/                 the parser-combinator engine and tokens
    Primitives, Unicode, Symbol, Keyword   ← Parse.*
    Identifier         split from Parse.Variable
Json/                  Decode, Encode, String           (unchanged)
Config                 ← Eco.Config
Elm/                   ModuleName, Package, Version, Constraint, Magnitude, Licenses
IR/                    the program representations and the platform model
    Source             ← AST.Source
    Source/            Binop, Shader ← AST.Utils.*; StringLiteral ← Elm.String
    Canonical          ← AST.Canonical
    Canonical/         Alias ← AST.Utils.Type; Interface ← Elm.Interface
    DecisionTree/      Path, Test, TypedPath ← AST.DecisionTree.*
    Optimized          ← AST.Optimized
    Typed/             TypeVars, Canonical, Optimized, TypeEnv, TypeTable, ModuleArtifact
    Mono               ← AST.Monomorphized
    Mono/              Abi ← AST.MonoAbi; Intern ← AST.Intern;
                       Closure, Registry, Traverse ← Monomorphize.*
    Kernel/            Chunk (split from Elm.Kernel), Facts, Abi (split from
                       Monomorphize.KernelAbi), Intrinsics
    Runtime/           CtorTag, HeapLimits ← Data.*; EcoEnvironment ← Elm.EcoEnvironment
Reporting/             Doc, Report, Result, Warning, Render/{Code, Type, Type/Localizer}

── Compiler/: passes, in order ──
Parse/                 + Error ← Reporting.Error.Syntax, DefaultImports ← Elm.Compiler.Imports,
                         Kernel ← Elm.Kernel (the kernel-file parser)
Docs                   ← Elm.Docs   (with Docs/Error, Docs/Type, Docs/Type/Extract)
Canonicalize/          + Dups, LocalEnvironment, Error, ImportError
Type/                  + Error ← Reporting.Error.Type, ErrorType ← Type.Error,
                         TypedCanonical ← TypedCanonical.Build, State/* ← System.TypeCheck.IO,
                         Data.IORef, Data.Vector, Data.Vector.Mutable
Nitpick/               + Error ← Reporting.Error.Pattern
LocalOpt/              + Error ← Reporting.Error.Main
GenerateJs             ← Generate.CodeGen.JavaScript (entry point)
GenerateJs/            Generate, CodeGen, Mode, Html, Builder, Expression, Functions, Name, SourceMap
PreMono/               EntryPrep, AssignMVarIds, Fresh, AliasForward, EtaExpand,
                       InlineSimplify, LiftClosedArgs
Monomorphize/          Analysis, Diff, KernelAbi, Prune, ResolveAccessorValues, State,
                       TypeSubst, ValidateLayout, ValidateLimits, Solver/*, Subst/*
MonoOpt/               InlineSimplify, GlobalOptimize, Cse, ReturnArity, AbiCloning,
                       Borrow, Borrow/*, CafCensus, CafDedupe, CafHoist, CseCensus,
                       CsePurity, FloatMinMax, GenCallCensus, ListCombinators,
                       MapTemplate, Staging
GenerateMlir/          ← Generate.MLIR.* (same names)

── Compiler/: orchestration ──
Error                  split from Reporting.Error: the union of the passes' errors
Compile, Pipeline/Steps

── Driver ──
Builder/               + Deps/Details ← Builder.Elm.Details,
                         Reporting/ModuleError (split from Compiler.Reporting.Error),
                         Reporting/Exit/JsonError ← Compiler.Reporting.Error.Json
API/, Terminal/, Common/   (unchanged)
```

Why the shared folders are cut this way:

- **`Core/`** holds what every representation and every message needs: names,
  positions in the source, interned strings, the id types, and name suggestions.
  It imports only the libraries.
- **`Lexer/`** is the combinator engine and the token-level parsers. Package names,
  module names, versions and JSON are all parsed with it, which is why it cannot
  stay inside `Parse/`.
- **`Elm/`** keeps only package and module identity: names, versions, constraints,
  licenses. Docs, the kernel-file parser, default imports and string literals move
  to where they are used.
- **`IR/`** replaces `AST/` and the planned `Kernel/`. It holds each program
  representation, from `Source` to `Mono`, with the helpers that belong to one
  representation in a folder of the same name. It also holds the model of the
  platform the compiler targets: `IR/Kernel/` for what is known about kernel
  functions, and `IR/Runtime/` for facts the runtime fixes.
- **`Reporting/`** keeps the machinery for building messages. Each pass's errors
  move into the pass, so no pass imports `Reporting` for its own types and
  `Reporting` imports no pass.

### Order of the top-level folders under `Compiler/`

This is the layer stack for step 5. No module imports a folder later in the list,
and `GenerateJs` and the typed branch do not import each other:

`Core`, `Lexer`, `Json`, `Config`, `Elm`, `IR`, `Reporting`, `Parse`, `Docs`,
`Canonicalize`, `Type`, `Nitpick`, `LocalOpt`, `GenerateJs` | `PreMono`,
`Monomorphize`, `MonoOpt`, `GenerateMlir`, `Error`, `Compile`, `Pipeline`.

## How the target was checked

The target was checked by applying the moves and splits below to the import graph
of `ac0896c0` and running the folder-cycle check on the result: no folder cycles
under either reading in rule 4, and no forward or cross-branch import between the
top-level folders of `Compiler/`. The splits were modelled by giving each new part
the imports its job needs and routing importers by what they use (for example,
`Lexer.Keyword` and `Elm.ModuleName` use only the width scanners of
`Parse.Variable`). Each split must be checked when it is made; step 6 runs the
check on the real tree.

## Step 1: edits and splits

Make these before any move, each as its own commit that builds and passes the
tests. Each split creates its new module at its final path.

1. **`Utils.Main.foldM` moves to `Compiler.Reporting.Result.foldM`.** It is a fold
   over `RResult`, and it is the only reason `Utils.Main` imports the compiler.
   Update its callers.
2. **MLIR generation stops carrying `Mode`.** `Generate.MLIR.Context` has a field
   `mode : Mode.Mode` that nothing reads. Remove the field and the `Mode`
   parameter of `initContext` and of `Generate.MLIR.Backend`'s `generateMlirModule`,
   `generateProgram` and `buildContext`. Update the callers: `Builder.Generate` and
   the tests `TestLogic.TestPipeline`, `TestLogic.Generate.EcoSystemManagerRegistrationTest`,
   `TestLogic.Generate.CodeGen.TypeTableUniqueness`,
   `TestLogic.Generate.CodeGen.SingletonConstantsTest` and
   `Compiler.PackageCompilation`.
3. **Split `Compiler.Parse.Variable`.** The character-level functions
   (`getInnerWidth`, `getInnerWidthHelp`, `getUpperWidth` and the other width
   scanners, `isReservedWord`, and the reserved-word set) go to a new
   `Compiler/Lexer/Identifier.elm`, importing only `Parse.Primitives`,
   `Parse.Unicode` and `Data.Set`. The parsers that build `Src` values stay in
   `Parse.Variable`, which imports `Identifier`. Point `Parse.Keyword`,
   `Elm.ModuleName`, `Reporting.Render.Code`, `Parse.Number`, `Parse.Pattern` and
   `Elm.Docs` at
   `Identifier` for the functions that moved.
4. **Split `Compiler.Elm.Kernel`.** The types `Chunk`, `Content` and `Foreigns`,
   with their encoders and decoders, go to a new `Compiler/IR/Kernel/Chunk.elm`.
   `AST.Optimized` and `AST.TypedOptimized` import only that module. The parser
   (which needs `Parse.Module`, `Parse.Space` and `Parse.Variable`) stays behind
   and moves to `Compiler/Parse/Kernel.elm` in step 3.
5. **Split `Compiler.Monomorphize.KernelAbi`.** `suffixSelectingKernels`,
   `alwaysPolymorphicModules` and `comparePair` go to a new
   `Compiler/IR/Kernel/Abi.elm`, which imports nothing from the compiler. The rest,
   which needs `Monomorphize.State.MVarEnv`, stays in `Monomorphize.KernelAbi`.
   `GlobalOpt.PreMono.AliasForward` imports only the new module.
6. **Split `Compiler.Reporting.Error`.** The `Error` union over the passes' errors
   (`BadSyntax`, `BadNames`, `BadTypes`, `BadMains`, `BadPatterns`, …) goes to a new
   `Compiler/Error.elm`; that is all `Compiler.Compile` uses. The rest goes to
   `Builder/Reporting/ModuleError.elm`: the per-module record with its
   `File.Time`, the conversion to reports, and the terminal and JSON output.
   `Builder.Build`, `Builder.Elm.Details`, `Builder.Reporting.Exit`,
   `Builder.Reporting.Exit.Help` and `API.Main` import it. After this,
   `Compiler/` no longer imports `Builder.File`.

## Step 2: how to move a module

Do the moves with a script that takes the old and new module names from the tables
below and, for each move:

1. moves the file with `git mv`, creating folders as needed;
2. rewrites the module name in every `.elm` file under `compiler/src`,
   `compiler/src-xhr`, `compiler/src-version`, `compiler/tests` and
   `compiler/review`: the `module` line, `import` lines, fully qualified references,
   and references in comments and doc comments.

Rewrite longest names first, and match a name only when it is not followed by a
letter, digit or `_`, or by a `.` and an upper-case letter. That way
`Compiler.Generate.JavaScript.Name` and `Compiler.Generate.JavaScript` are handled
separately, `Data.Vector` does not catch `Data.Vector.Mutable`, and a qualified
value such as `Compiler.Generate.JavaScript.generate` is still renamed.

Imports with an alias (`import Compiler.AST.Canonical as Can`) need nothing else.
Run `elm-format` on the changed files, since import lists are sorted.

Two renames must be done in order: `Compiler.Type.Error` → `Compiler.Type.ErrorType`
first, then `Compiler.Reporting.Error.Type` → `Compiler.Type.Error`.

## Step 3: file moves

Do one table per commit. After each, build the compiler (`build-xhr` and native),
run `npm test` in `compiler/`, and run `npm run review`.

These two moves happen as part of the splits in step 1:

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/Elm/Kernel.elm` (the parser left after split 4) | `Compiler/Parse/Kernel.elm` |
| `Compiler/Reporting/Error.elm` (what is left after split 6) | `Builder/Reporting/ModuleError.elm` |

Two data files move with `MonoSolver/`:

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/MonoSolver/kernel-license-audit.csv` | `Compiler/Monomorphize/Solver/kernel-license-audit.csv` |
| `Compiler/MonoSolver/kernel-license-files.csv` | `Compiler/Monomorphize/Solver/kernel-license-files.csv` |

The module moves, 142 in all:


### Libraries (8)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/Data/Bag.elm` | `Data/Bag.elm` |
| `Compiler/Data/BitSet.elm` | `Data/BitSet.elm` |
| `Compiler/Graph.elm` | `Data/Graph.elm` |
| `Compiler/Data/Int64.elm` | `Data/Int64.elm` |
| `Compiler/Data/Map/Utils.elm` | `Data/Map/Utils.elm` |
| `Compiler/Data/NonEmptyList.elm` | `Data/NonEmptyList.elm` |
| `Compiler/Data/OneOrMore.elm` | `Data/OneOrMore.elm` |
| `Utils/Crash.elm` | `System/Crash.elm` |

### Core and Config (10)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/Eco/Config.elm` | `Compiler/Config.elm` |
| `Compiler/Reporting/Annotation.elm` | `Compiler/Core/Annotation.elm` |
| `Compiler/Data/Id.elm` | `Compiler/Core/Id.elm` |
| `Compiler/Data/Index.elm` | `Compiler/Core/Index.elm` |
| `Compiler/Data/IndexName.elm` | `Compiler/Core/IndexName.elm` |
| `Compiler/Data/Name.elm` | `Compiler/Core/Name.elm` |
| `Compiler/AST/Snippet.elm` | `Compiler/Core/Snippet.elm` |
| `Compiler/AST/StringTable.elm` | `Compiler/Core/StringTable.elm` |
| `Compiler/Reporting/Suggest.elm` | `Compiler/Core/Suggest.elm` |
| `Compiler/AST/TypeIds.elm` | `Compiler/Core/TypeIds.elm` |

### Lexer (4)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/Parse/Keyword.elm` | `Compiler/Lexer/Keyword.elm` |
| `Compiler/Parse/Primitives.elm` | `Compiler/Lexer/Primitives.elm` |
| `Compiler/Parse/Symbol.elm` | `Compiler/Lexer/Symbol.elm` |
| `Compiler/Parse/Unicode.elm` | `Compiler/Lexer/Unicode.elm` |

### IR (28)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/AST/Canonical.elm` | `Compiler/IR/Canonical.elm` |
| `Compiler/AST/Utils/Type.elm` | `Compiler/IR/Canonical/Alias.elm` |
| `Compiler/Elm/Interface.elm` | `Compiler/IR/Canonical/Interface.elm` |
| `Compiler/AST/DecisionTree/Path.elm` | `Compiler/IR/DecisionTree/Path.elm` |
| `Compiler/AST/DecisionTree/Test.elm` | `Compiler/IR/DecisionTree/Test.elm` |
| `Compiler/AST/DecisionTree/TypedPath.elm` | `Compiler/IR/DecisionTree/TypedPath.elm` |
| `Compiler/GlobalOpt/KernelFacts.elm` | `Compiler/IR/Kernel/Facts.elm` |
| `Compiler/GlobalOpt/KernelIntrinsics.elm` | `Compiler/IR/Kernel/Intrinsics.elm` |
| `Compiler/AST/Monomorphized.elm` | `Compiler/IR/Mono.elm` |
| `Compiler/AST/MonoAbi.elm` | `Compiler/IR/Mono/Abi.elm` |
| `Compiler/Monomorphize/Closure.elm` | `Compiler/IR/Mono/Closure.elm` |
| `Compiler/AST/Intern.elm` | `Compiler/IR/Mono/Intern.elm` |
| `Compiler/Monomorphize/Registry.elm` | `Compiler/IR/Mono/Registry.elm` |
| `Compiler/Monomorphize/MonoTraverse.elm` | `Compiler/IR/Mono/Traverse.elm` |
| `Compiler/AST/Optimized.elm` | `Compiler/IR/Optimized.elm` |
| `Compiler/Data/CtorTag.elm` | `Compiler/IR/Runtime/CtorTag.elm` |
| `Compiler/Elm/EcoEnvironment.elm` | `Compiler/IR/Runtime/EcoEnvironment.elm` |
| `Compiler/Data/HeapLimits.elm` | `Compiler/IR/Runtime/HeapLimits.elm` |
| `Compiler/AST/Source.elm` | `Compiler/IR/Source.elm` |
| `Compiler/AST/Utils/Binop.elm` | `Compiler/IR/Source/Binop.elm` |
| `Compiler/AST/Utils/Shader.elm` | `Compiler/IR/Source/Shader.elm` |
| `Compiler/Elm/String.elm` | `Compiler/IR/Source/StringLiteral.elm` |
| `Compiler/AST/TypedCanonical.elm` | `Compiler/IR/Typed/Canonical.elm` |
| `Compiler/AST/TypedModuleArtifact.elm` | `Compiler/IR/Typed/ModuleArtifact.elm` |
| `Compiler/AST/TypedOptimized.elm` | `Compiler/IR/Typed/Optimized.elm` |
| `Compiler/AST/TypeEnv.elm` | `Compiler/IR/Typed/TypeEnv.elm` |
| `Compiler/AST/TypeTable.elm` | `Compiler/IR/Typed/TypeTable.elm` |
| `Compiler/AST/TypeVars.elm` | `Compiler/IR/Typed/TypeVars.elm` |

### Pass error modules and pass-owned helpers (19)

In this table, `Type/Error.elm` → `Type/ErrorType.elm` must happen before `Reporting/Error/Type.elm` → `Type/Error.elm`.

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/Canonicalize/Environment/Dups.elm` | `Compiler/Canonicalize/Dups.elm` |
| `Compiler/Reporting/Error/Canonicalize.elm` | `Compiler/Canonicalize/Error.elm` |
| `Compiler/Reporting/Error/Import.elm` | `Compiler/Canonicalize/ImportError.elm` |
| `Compiler/Canonicalize/Environment/Local.elm` | `Compiler/Canonicalize/LocalEnvironment.elm` |
| `Compiler/Elm/Docs.elm` | `Compiler/Docs.elm` |
| `Compiler/Reporting/Error/Docs.elm` | `Compiler/Docs/Error.elm` |
| `Compiler/Elm/Compiler/Type.elm` | `Compiler/Docs/Type.elm` |
| `Compiler/Elm/Compiler/Type/Extract.elm` | `Compiler/Docs/Type/Extract.elm` |
| `Compiler/Reporting/Error/Main.elm` | `Compiler/LocalOpt/Error.elm` |
| `Compiler/Reporting/Error/Pattern.elm` | `Compiler/Nitpick/Error.elm` |
| `Compiler/Elm/Compiler/Imports.elm` | `Compiler/Parse/DefaultImports.elm` |
| `Compiler/Reporting/Error/Syntax.elm` | `Compiler/Parse/Error.elm` |
| `Compiler/Type/Error.elm` | `Compiler/Type/ErrorType.elm` |
| `Compiler/Reporting/Error/Type.elm` | `Compiler/Type/Error.elm` |
| `System/TypeCheck/IO.elm` | `Compiler/Type/State/IO.elm` |
| `Data/IORef.elm` | `Compiler/Type/State/IORef.elm` |
| `Data/Vector.elm` | `Compiler/Type/State/Vector.elm` |
| `Data/Vector/Mutable.elm` | `Compiler/Type/State/Vector/Mutable.elm` |
| `Compiler/TypedCanonical/Build.elm` | `Compiler/Type/TypedCanonical.elm` |

### JavaScript back end (10)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/Generate/CodeGen/JavaScript.elm` | `Compiler/GenerateJs.elm` |
| `Compiler/Generate/JavaScript/Builder.elm` | `Compiler/GenerateJs/Builder.elm` |
| `Compiler/Generate/CodeGen.elm` | `Compiler/GenerateJs/CodeGen.elm` |
| `Compiler/Generate/JavaScript/Expression.elm` | `Compiler/GenerateJs/Expression.elm` |
| `Compiler/Generate/JavaScript/Functions.elm` | `Compiler/GenerateJs/Functions.elm` |
| `Compiler/Generate/JavaScript.elm` | `Compiler/GenerateJs/Generate.elm` |
| `Compiler/Generate/Html.elm` | `Compiler/GenerateJs/Html.elm` |
| `Compiler/Generate/Mode.elm` | `Compiler/GenerateJs/Mode.elm` |
| `Compiler/Generate/JavaScript/Name.elm` | `Compiler/GenerateJs/Name.elm` |
| `Compiler/Generate/JavaScript/SourceMap.elm` | `Compiler/GenerateJs/SourceMap.elm` |

### Pre-mono (7)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/GlobalOpt/PreMono/AliasForward.elm` | `Compiler/PreMono/AliasForward.elm` |
| `Compiler/Monomorphize/AssignMVarIds.elm` | `Compiler/PreMono/AssignMVarIds.elm` |
| `Compiler/Monomorphize/EntryPrep.elm` | `Compiler/PreMono/EntryPrep.elm` |
| `Compiler/GlobalOpt/PreMono/EtaExpand.elm` | `Compiler/PreMono/EtaExpand.elm` |
| `Compiler/GlobalOpt/PreMono/Fresh.elm` | `Compiler/PreMono/Fresh.elm` |
| `Compiler/GlobalOpt/InlineSimplify.elm` | `Compiler/PreMono/InlineSimplify.elm` |
| `Compiler/GlobalOpt/PreMono/LiftClosedArgs.elm` | `Compiler/PreMono/LiftClosedArgs.elm` |

### Mono (10)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/MonoSolver/Diff.elm` | `Compiler/Monomorphize/Diff.elm` |
| `Compiler/MonoSolver/Engine.elm` | `Compiler/Monomorphize/Solver/Engine.elm` |
| `Compiler/MonoSolver/KernelSetFacts.elm` | `Compiler/Monomorphize/Solver/KernelSetFacts.elm` |
| `Compiler/MonoSolver/LssInfer.elm` | `Compiler/Monomorphize/Solver/LssInfer.elm` |
| `Compiler/MonoSolver/Monomorphize.elm` | `Compiler/Monomorphize/Solver/Monomorphize.elm` |
| `Compiler/MonoSolver/Store.elm` | `Compiler/Monomorphize/Solver/Store.elm` |
| `Compiler/MonoSolver/Translate.elm` | `Compiler/Monomorphize/Solver/Translate.elm` |
| `Compiler/MonoSolver/Zonk.elm` | `Compiler/Monomorphize/Solver/Zonk.elm` |
| `Compiler/Monomorphize/Monomorphize.elm` | `Compiler/Monomorphize/Subst/Monomorphize.elm` |
| `Compiler/Monomorphize/Specialize.elm` | `Compiler/Monomorphize/Subst/Specialize.elm` |

### Mono-opt (26)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/GlobalOpt/AbiCloning.elm` | `Compiler/MonoOpt/AbiCloning.elm` |
| `Compiler/GlobalOpt/Borrow.elm` | `Compiler/MonoOpt/Borrow.elm` |
| `Compiler/GlobalOpt/Borrow/Constrain.elm` | `Compiler/MonoOpt/Borrow/Constrain.elm` |
| `Compiler/GlobalOpt/Borrow/Dsu.elm` | `Compiler/MonoOpt/Borrow/Dsu.elm` |
| `Compiler/GlobalOpt/Borrow/Facts.elm` | `Compiler/MonoOpt/Borrow/Facts.elm` |
| `Compiler/GlobalOpt/Borrow/KernelSigs.elm` | `Compiler/MonoOpt/Borrow/KernelSigs.elm` |
| `Compiler/GlobalOpt/Borrow/Lifetime.elm` | `Compiler/MonoOpt/Borrow/Lifetime.elm` |
| `Compiler/GlobalOpt/Borrow/LssFacts.elm` | `Compiler/MonoOpt/Borrow/LssFacts.elm` |
| `Compiler/GlobalOpt/Borrow/Mode.elm` | `Compiler/MonoOpt/Borrow/Mode.elm` |
| `Compiler/GlobalOpt/Borrow/Rty.elm` | `Compiler/MonoOpt/Borrow/Rty.elm` |
| `Compiler/GlobalOpt/Borrow/Sig.elm` | `Compiler/MonoOpt/Borrow/Sig.elm` |
| `Compiler/GlobalOpt/Borrow/Solve.elm` | `Compiler/MonoOpt/Borrow/Solve.elm` |
| `Compiler/GlobalOpt/CafCensus.elm` | `Compiler/MonoOpt/CafCensus.elm` |
| `Compiler/GlobalOpt/CafDedupe.elm` | `Compiler/MonoOpt/CafDedupe.elm` |
| `Compiler/GlobalOpt/CafHoist.elm` | `Compiler/MonoOpt/CafHoist.elm` |
| `Compiler/GlobalOpt/MonoCse.elm` | `Compiler/MonoOpt/Cse.elm` |
| `Compiler/GlobalOpt/CseCensus.elm` | `Compiler/MonoOpt/CseCensus.elm` |
| `Compiler/GlobalOpt/CsePurity.elm` | `Compiler/MonoOpt/CsePurity.elm` |
| `Compiler/GlobalOpt/FloatMinMax.elm` | `Compiler/MonoOpt/FloatMinMax.elm` |
| `Compiler/GlobalOpt/GenCallCensus.elm` | `Compiler/MonoOpt/GenCallCensus.elm` |
| `Compiler/GlobalOpt/MonoGlobalOptimize.elm` | `Compiler/MonoOpt/GlobalOptimize.elm` |
| `Compiler/GlobalOpt/MonoInlineSimplify.elm` | `Compiler/MonoOpt/InlineSimplify.elm` |
| `Compiler/GlobalOpt/ListCombinators.elm` | `Compiler/MonoOpt/ListCombinators.elm` |
| `Compiler/GlobalOpt/MapTemplate.elm` | `Compiler/MonoOpt/MapTemplate.elm` |
| `Compiler/GlobalOpt/MonoReturnArity.elm` | `Compiler/MonoOpt/ReturnArity.elm` |
| `Compiler/GlobalOpt/Staging.elm` | `Compiler/MonoOpt/Staging.elm` |

### MLIR back end (18)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Compiler/Generate/MLIR/Backend.elm` | `Compiler/GenerateMlir/Backend.elm` |
| `Compiler/Generate/MLIR/BytesFusion/Emit.elm` | `Compiler/GenerateMlir/BytesFusion/Emit.elm` |
| `Compiler/Generate/MLIR/BytesFusion/LoopIR.elm` | `Compiler/GenerateMlir/BytesFusion/LoopIR.elm` |
| `Compiler/Generate/MLIR/BytesFusion/Reify.elm` | `Compiler/GenerateMlir/BytesFusion/Reify.elm` |
| `Compiler/Generate/MLIR/ConstThunks.elm` | `Compiler/GenerateMlir/ConstThunks.elm` |
| `Compiler/Generate/MLIR/Context.elm` | `Compiler/GenerateMlir/Context.elm` |
| `Compiler/Generate/MLIR/Expr.elm` | `Compiler/GenerateMlir/Expr.elm` |
| `Compiler/Generate/MLIR/Functions.elm` | `Compiler/GenerateMlir/Functions.elm` |
| `Compiler/Generate/MLIR/Intrinsics.elm` | `Compiler/GenerateMlir/Intrinsics.elm` |
| `Compiler/Generate/MLIR/KernelAbi.elm` | `Compiler/GenerateMlir/KernelAbi.elm` |
| `Compiler/Generate/MLIR/Lambdas.elm` | `Compiler/GenerateMlir/Lambdas.elm` |
| `Compiler/Generate/MLIR/LogicalTypes.elm` | `Compiler/GenerateMlir/LogicalTypes.elm` |
| `Compiler/Generate/MLIR/Names.elm` | `Compiler/GenerateMlir/Names.elm` |
| `Compiler/Generate/MLIR/Ops.elm` | `Compiler/GenerateMlir/Ops.elm` |
| `Compiler/Generate/MLIR/Patterns.elm` | `Compiler/GenerateMlir/Patterns.elm` |
| `Compiler/Generate/MLIR/TailRec.elm` | `Compiler/GenerateMlir/TailRec.elm` |
| `Compiler/Generate/MLIR/TypeTable.elm` | `Compiler/GenerateMlir/TypeTable.elm` |
| `Compiler/Generate/MLIR/Types.elm` | `Compiler/GenerateMlir/Types.elm` |

### Builder (2)

| from (`compiler/src/`) | to (`compiler/src/`) |
|---|---|
| `Builder/Elm/Details.elm` | `Builder/Deps/Details.elm` |
| `Compiler/Reporting/Error/Json.elm` | `Builder/Reporting/Exit/JsonError.elm` |


## Step 4: references outside the Elm sources

These name moved files by path and must be updated in the same commit as the move
that affects them:

| File | Reference | New value |
|---|---|---|
| `CMakeLists.txt` (around lines 1291–1323) | `compiler/src/Compiler/MonoSolver/KernelSetFacts.elm`, `kernel-license-files.csv`, `kernel-license-audit.csv` | `compiler/src/Compiler/Monomorphize/Solver/…` |
| `test/scripts/check-kernel-homes.sh` | `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`, `compiler/src/Compiler/MonoSolver/KernelSetFacts.elm` | `compiler/src/Compiler/IR/Kernel/Facts.elm`, `compiler/src/Compiler/Monomorphize/Solver/KernelSetFacts.elm` |
| `test/scripts/check-kernel-license-manifest.sh` | `DIR="$ROOT/compiler/src/Compiler/MonoSolver"` | `…/Compiler/Monomorphize/Solver` |
| `benchmarks/lss-coupdate-census.py` | `compiler/src/Compiler/MonoSolver/*.elm` | `compiler/src/Compiler/Monomorphize/Solver/*.elm` |
| `compiler/review/src/ReviewConfig.elm` | the ignore entry `src/Utils/Crash.elm` | `src/System/Crash.elm` |
| `compiler/src-xhr` | `import Utils.Crash` | `import System.Crash` (covered by the rewrite in step 2) |

`compiler/tests` imports moved modules from about 350 files; the rewrite in step 2
covers them. The test modules keep their own names (`TestLogic.*`, `SourceIR.*`,
`Compiler.*`); moving them to mirror the new tree is optional and not part of
this plan.

Prose that names moved modules (about 45 files in `design_docs/`, `docs/` and
`guides/`, and many plans) can be updated with the same rewrite. Plans that are
done are history and should be left as they are.

Outside this repository, the knowledge graph in `www-eco-lang/kg` places modules
into stages by name (`kg/src/Kg/Stages.elm`: entry modules such as
`Compiler.Monomorphize.Monomorphize`, `Compiler.GlobalOpt.MonoGlobalOptimize` and
`Compiler.Generate.MLIR.Backend`, and prefixes such as `Compiler.GlobalOpt.`). It
needs the new names once this lands; until then the atlas will show the old
layout.

## Step 5: enforce the structure

1. **Replace the layer stack in `compiler/review/src/ReviewConfig.elm`.** Today it
   lists `AST`, `Parse`, `Canonicalize`, `Type`, `Nitpick`, `LocalOpt`,
   `Monomorphize`, `GlobalOpt` and `Generate`, and leaves everything else
   unchecked. Use the order given under "Order of the top-level folders", one
   `PrefixLayer` per folder (`[ "Compiler", "Core" ]`, `[ "Compiler", "Lexer" ]`,
   …), with `GenerateJs` placed before `PreMono`. `EnforceBoundaries` checks a
   single stack, so it cannot see that `PreMono` must not import `GenerateJs`; the
   folder-cycle check below does not see it either. Add a second, small rule (or
   a case in `EnforceBoundaries`) that forbids imports between `Compiler.GenerateJs`
   and `Compiler.PreMono`, `Compiler.Monomorphize`, `Compiler.MonoOpt` and
   `Compiler.GenerateMlir`, in both directions.
2. **Add `compiler/scripts/check-folder-cycles.py`** (appendix A) and run it with
   and without `--merge` from the same place the other source checks run (the
   `test/scripts/check-*.sh` group, or a CTest entry next to the kernel-license
   checks). It must report `0 folder cycle(s)` both ways.

## Step 6: done when

- every file in the tables above is at its new path, and no `.elm` file under
  `compiler/` names an old module;
- the compiler builds (XHR and native), `npm test` passes in `compiler/`, and the
  self-compile and the kernel-license and kernel-homes checks pass;
- `npm run review` passes with the new layer stack and the branch rule;
- `check-folder-cycles.py compiler/src` and `check-folder-cycles.py compiler/src --merge`
  both report no cycles.

## Out of scope

- Splitting the large modules (`Generate.MLIR.Expr`, `MonoSolver.Translate`,
  `Reporting.Error.Syntax`, …) or renaming anything that does not move.
- `Builder.Generate` imports about fifteen middle-end modules directly instead of
  going through `Compiler.Pipeline.Steps`. That is worth fixing, separately.
- Backward imports that are allowed but odd:
  - `Generate.MLIR.Backend` runs `GlobalOpt.MapTemplate.derive` and
    `GlobalOpt.MonoInlineSimplify.buildBodyLookup` itself.
  - `Generate.MLIR.Expr`, `Patterns` and `TailRec` and `Monomorphize.Specialize`
    import `LocalOpt.Typed.DecisionTree` only for its `Test` alias and could import
    `AST.DecisionTree.Test`.

## Appendix A: `check-folder-cycles.py`

```python
#!/usr/bin/env python3
"""Fails when two sibling folders under compiler/src depend on each other.

A folder contains everything beneath it. At every folder, each child (a
subfolder or a module file) is a node, and a child depends on a sibling when
any module inside it imports any module inside the sibling. Any cycle among
siblings is reported. With --merge, Foo.elm counts as part of Foo/.
"""
import os, re, sys
from collections import defaultdict

root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else 'compiler/src'
merge = '--merge' in sys.argv

mods = {}
for d, _, fs in os.walk(root):
    for f in fs:
        if f.endswith('.elm'):
            p = os.path.join(d, f)
            name = os.path.relpath(p, root)[:-4].replace(os.sep, '.')
            src = open(p, encoding='utf-8').read()
            mods[name] = re.findall(r'^import\s+([A-Z][\w.]*)', src, re.M)
mods = {k: [i for i in v if i in mods] for k, v in mods.items()}


def child(parent, mod):
    p = mod.split('.')
    if p[:len(parent)] != parent or len(p) == len(parent):
        return None
    c = p[len(parent)]
    return c + '.elm' if len(p) == len(parent) + 1 and not merge else c


def sccs(nodes, edges):
    index, low, stack, on, out, n = {}, {}, [], set(), [], [0]

    def visit(v):
        index[v] = low[v] = n[0]; n[0] += 1; stack.append(v); on.add(v)
        for w in edges[v]:
            if w not in index:
                visit(w); low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop(); on.discard(w); comp.append(w)
                if w == v:
                    break
            out.append(comp)

    for v in sorted(nodes):
        if v not in index:
            visit(v)
    return out


sys.setrecursionlimit(10000)
dirs = {tuple(m.split('.')[:i]) for m in mods for i in range(len(m.split('.')))}
cycles = 0
for d in sorted(dirs):
    d = list(d)
    edges, example, nodes = defaultdict(set), {}, set()
    for mod, imps in mods.items():
        a = child(d, mod)
        if a is None:
            continue
        nodes.add(a)
        for i in imps:
            b = child(d, i)
            if b is not None and b != a:
                edges[a].add(b)
                example.setdefault((a, b), (mod, i))
    for comp in sccs(nodes, edges):
        if len(comp) > 1:
            cycles += 1
            members = set(comp)
            print(f"cycle in {'/'.join(d) or '.'}/: {', '.join(sorted(comp))}")
            for (a, b), (x, y) in sorted(example.items()):
                if a in members and b in members:
                    print(f"    {a} -> {b}   e.g. {x} imports {y}")
print(f"{cycles} folder cycle(s)")
sys.exit(1 if cycles else 0)
```
