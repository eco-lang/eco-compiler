# Plan: Standardize Import Aliases with elm-review-imports

## Goal
Enforce consistent import alias names across the entire compiler codebase using `sparksp/elm-review-imports`'s `NoInconsistentAliases` rule.

---

## Step 1: Install `sparksp/elm-review-imports` in elm-review project

```bash
cd compiler/review
elm install sparksp/elm-review-imports
```

This adds `sparksp/elm-review-imports` to `compiler/review/elm.json` dependencies.

---

## Step 2: Add `NoInconsistentAliases` rule to `ReviewConfig.elm`

Add the import and configure the rule with the full alias table from Step 3:

```elm
import NoInconsistentAliases

config =
    [ ...existing rules...
    , NoInconsistentAliases.config
        [ ( "Builder.Deps.Diff", "Diff" )
        , ( "Compiler.AST.DecisionTree.Path", "Path" )
        , ( "Compiler.AST.DecisionTree.Test", "Test" )
        , ( "Compiler.AST.DecisionTree.TypedPath", "TypedPath" )
        , ( "Compiler.Data.Name", "Name" )
        , ( "Compiler.Elm.Compiler.Type", "CompType" )
        , ( "Compiler.Elm.Constraint", "Con" )
        , ( "Compiler.Elm.Kernel", "Kernel" )
        , ( "Compiler.Generate.JavaScript.Name", "JsName" )
        , ( "Compiler.Generate.MLIR.Context", "Ctx" )
        , ( "Compiler.Json.Decode", "Decode" )
        , ( "Compiler.Json.Encode", "Encode" )
        , ( "Compiler.Nitpick.PatternMatches", "PatMatch" )
        , ( "Compiler.Parse.Declaration", "Decl" )
        , ( "Compiler.Parse.Expression", "Expr" )
        , ( "Compiler.Parse.Keyword", "Keyword" )
        , ( "Compiler.Parse.Module", "Module" )
        , ( "Compiler.Parse.Space", "Space" )
        , ( "Compiler.Parse.Type", "Type" )
        , ( "Compiler.Parse.Variable", "Var" )
        , ( "Compiler.Reporting.Doc", "Doc" )
        , ( "Compiler.Reporting.Error", "Error" )
        , ( "Compiler.Reporting.Error.Canonicalize", "Canonicalize" )
        , ( "Compiler.Reporting.Error.Docs", "ErrorDocs" )
        , ( "Compiler.Reporting.Error.Main", "ErrorMain" )
        , ( "Compiler.Reporting.Error.Syntax", "Syntax" )
        , ( "Compiler.Reporting.Error.Type", "ErrorType" )
        , ( "Compiler.Reporting.Render.Type", "RenderType" )
        , ( "Compiler.Reporting.Render.Type.Localizer", "Localizer" )
        , ( "Compiler.Reporting.Warning", "Warning" )
        , ( "Compiler.Type.Error", "TypeError" )
        , ( "Data.Map", "AnyDict" )
        , ( "Dict", "Dict" )
        , ( "List.Extra", "List" )
        , ( "System.IO", "IO" )
        , ( "System.TypeCheck.IO", "IO" )
        , ( "Utils.Task.Extra", "Task" )
        ]
        |> NoInconsistentAliases.rule
    ]
```

---

## Step 3: Chosen canonical aliases

### Standard modules (pick dominant or most descriptive alias)

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `Builder.Deps.Diff` | `Diff` | DD=1, Diff=1 | 1 (DD→Diff) |
| `Compiler.Data.Name` | `Name` | N=3, Name=76 | 3 (N→Name) |
| `Compiler.Generate.JavaScript.Name` | `JsName` | JSName=1, JsName=3, Name=1 | 2 (JSName→JsName, Name→JsName) |
| `Compiler.Generate.MLIR.Context` | `Ctx` | Context=1, Ctx=9 | 1 (Context→Ctx) |
| `Compiler.Parse.Declaration` | `Decl` | Decl=2, PD=1 | 1 (PD→Decl) |
| `Compiler.Parse.Expression` | `Expr` | Expr=2, PE=1 | 1 (PE→Expr) |
| `Compiler.Parse.Space` | `Space` | PS=1, Space=7 | 1 (PS→Space) |
| `Compiler.Parse.Type` | `Type` | PT=1, Type=3 | 1 (PT→Type) |
| `Compiler.Parse.Variable` | `Var` | PV=1, Var=11 | 1 (PV→Var) |
| `List.Extra` | `List` | List=8, ListX=1 | 1 (ListX→List) |
| `System.TypeCheck.IO` | `IO` | IO=65, TypeCheck=5 | 5 (TypeCheck→IO) |

### Short descriptive aliases (replacing single/double-letter abbreviations)

| Module | Old Alias(es) | Canonical Alias | Current State | Files to Change |
|---|---|---|---|---|
| `Compiler.Elm.Compiler.Type` | T, Type | `CompType` | T=1, Type=4 | 5 (all→CompType) |
| `Compiler.Elm.Constraint` | C, Con | `Con` | C=8, Con=3 | 8 (C→Con) |
| `Compiler.Elm.Kernel` | K, Kernel | `Kernel` | K=4, Kernel=2 | 4 (K→Kernel) |
| `Compiler.Nitpick.PatternMatches` | P, PatternMatches | `PatMatch` | P=2, PatternMatches=1 | 3 (all→PatMatch) |
| `Compiler.Reporting.Doc` | D, Doc | `Doc` | D=27, Doc=2 | 27 (D→Doc) |
| `Compiler.Reporting.Render.Type` | RT, Type | `RenderType` | RT=7, Type=1 | 8 (all→RenderType) |
| `Compiler.Reporting.Render.Type.Localizer` | L, Localizer | `Localizer` | L=12, Localizer=1 | 12 (L→Localizer) |
| `Compiler.Reporting.Warning` | W, Warning | `Warning` | W=4, Warning=1 | 4 (W→Warning) |
| `Compiler.Type.Error` | ET, Error, T | `TypeError` | ET=2, Error=1, T=1 | 4 (all→TypeError) |

### Conflict resolution: Json.Decode / Json.Encode

`Compiler.Json.Decode as D` and `Compiler.Reporting.Doc as Doc` coexist in 3 files. Both now get descriptive names, resolving the conflict cleanly.

`Compiler.Json.Encode as E` and `Compiler.Reporting.Error` coexist in 5 files.

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `Compiler.Json.Decode` | `Decode` | D=12, Decode=1 | 12 (D→Decode) |
| `Compiler.Json.Encode` | `Encode` | E=14, Encode=3, Json=1 | 15 (E→Encode, Json→Encode) |

### Conflict resolution: Reporting.Error and submodules

`Compiler.Reporting.Error.elm` is the aggregator that imports all submodules. Submodules get descriptive names; `ErrorDocs`, `ErrorMain`, and `ErrorType` use the `Error` prefix to avoid clashes with `Compiler.Elm.Docs` and the heavily-overloaded `Type` alias.

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `Compiler.Reporting.Error` | `Error` | E=1, Error=5 | 1 (E→Error) |
| `Compiler.Reporting.Error.Canonicalize` | `Canonicalize` | Canonicalize=1, E=1, Error=9 | 10 (E→Canonicalize, Error→Canonicalize) |
| `Compiler.Reporting.Error.Docs` | `ErrorDocs` | Docs=1, E=1, EDocs=1 | 3 (all→ErrorDocs) |
| `Compiler.Reporting.Error.Main` | `ErrorMain` | E=2, Main=1 | 3 (all→ErrorMain) |
| `Compiler.Reporting.Error.Syntax` | `Syntax` | E=13, ES=1, Syntax=3 | 14 (E→Syntax, ES→Syntax) |
| `Compiler.Reporting.Error.Type` | `ErrorType` | E=8, Error=1, Type=1 | 10 (all→ErrorType) |

### Conflict resolution: `K` alias (Elm.Kernel vs Parse.Keyword)

Both previously used `K` in different files. Now both get descriptive names.

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `Compiler.Elm.Kernel` | `Kernel` | K=4, Kernel=2 | 4 (K→Kernel) |
| `Compiler.Parse.Keyword` | `Keyword` | K=1, Keyword=4 | 1 (K→Keyword) |

### Conflict resolution: `Compiler.Parse.Module`

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `Compiler.Parse.Module` | `Module` | M=6, Module=1, PM=1, Parse=3 | 10 (M→Module, PM→Module, Parse→Module) |

### Conflict resolution: DecisionTree `DT` alias

AST files import multiple DecisionTree submodules as `DT` simultaneously (alias shadowing). Fix by using specific names. `Compiler.LocalOpt.*.DecisionTree as DT` is unaffected (consistent, no conflicts).

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `Compiler.AST.DecisionTree.Path` | `Path` | DT=1, Path=2 | 1 (DT→Path) |
| `Compiler.AST.DecisionTree.Test` | `Test` | DT=3, Test=6 | 3 (DT→Test) |
| `Compiler.AST.DecisionTree.TypedPath` | `TypedPath` | DT=2, TypedPath=2 | 2 (DT→TypedPath) |

### NEW: `Data.Map` / `Dict` conflict

`Data.Map` is a compatibility shim for `Dict`-like operations. 44 of 72 files that import `Data.Map` also import core `Dict`. The old plan used `Dict` as the alias, but this directly conflicts with core `Dict` in those 44 files (causing workarounds like `StdDict`, `CoreDict`).

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `Data.Map` | `AnyDict` | Dict=26, EveryDict=7, DataMap=6, DMap=3, Map=2 | 44 (all aliased→AnyDict) |
| `Dict` | `Dict` (no alias needed) | (bare)=98, StdDict=2, CoreDict=1 | 3 (StdDict→Dict, CoreDict→Dict; once Data.Map is AnyDict these workarounds are unnecessary) |

Note: 25 files import `Data.Map` without any alias (bare `import Data.Map`). These won't be caught by `NoInconsistentAliases` since the rule only checks `as` aliases. Those files should have `as AnyDict` added manually or via a separate rule.

### NEW: `System.IO` alias

`System.IO` and `System.TypeCheck.IO` never coexist, so both can safely use `IO`.

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `System.IO` | `IO` | IO=25, SysIO=1 | 1 (SysIO→IO) |

### NEW: `Utils.Task.Extra` alias

| Module | Canonical Alias | Current State | Files to Change |
|---|---|---|---|
| `Utils.Task.Extra` | `Task` | Task=15, TaskExtra=1 | 1 (TaskExtra→Task) |

---

## Step 4: Run elm-review to identify all violations

```bash
cd compiler
npx elm-review --config review/
```

This will report every file where an import alias doesn't match the canonical choice. The user will run `--fix` / `--fix-all` themselves.

---

## Step 5: Handle edge cases manually

### Known special files

1. **`src/Compiler/Elm/Compiler/Type.elm`** — currently imports both `Compiler.Json.Decode as D` and `Compiler.Reporting.Doc as D` (actual alias shadowing). Both will be flagged: Json.Decode→`Decode`, Reporting.Doc→`Doc`.

2. **`src/Compiler/Reporting/Error.elm`** — the aggregator file that imports all Error submodules. Currently uses short names (Canonicalize, Docs, Main, Syntax, Type) which are close to the chosen aliases. Also imports `Compiler.Json.Encode as E` which will change to `Encode`. Changes needed: `Error.Docs`→`ErrorDocs`, `Error.Main`→`ErrorMain`, `Error.Type`→`ErrorType`.

3. **`src/Builder/Build.elm`** — imports both `Compiler.Elm.Docs as Docs` and `Compiler.Reporting.Error.Docs as EDocs`. Under the new scheme: `Elm.Docs` stays `Docs`, `Error.Docs` becomes `ErrorDocs`.

4. **`src/Compiler/Type/Constrain/Erased/Expression.elm`** and **`src/Compiler/Type/Constrain/Typed/Expression.elm`** — currently import `Data.Map as Dict` and `Dict as StdDict`. Once `Data.Map` becomes `AnyDict`, these can revert `Dict` to a bare import.

5. **25 files with bare `import Data.Map`** (no alias) — `NoInconsistentAliases` only checks `as` aliases, so these won't be auto-flagged. They should be updated manually to `import Data.Map as AnyDict`.

If any file legitimately cannot use the canonical alias, add `Rule.ignoreErrorsForFiles` for that specific file.

---

## Step 6: Verify the codebase still compiles

```bash
cd compiler
npx elm-test-rs --project build-xhr --fuzz 1
cmake --build build --target check
```

---

## Total estimated changes

| Category | Files Affected |
|---|---|
| `Data.Map` →AnyDict (aliased + bare) | ~69 |
| `Compiler.Reporting.Doc` D→Doc | ~27 |
| `Compiler.Reporting.Error.*` submodule renames | ~41 |
| `Compiler.Json.Encode` E→Encode | ~15 |
| `Compiler.Json.Decode` D→Decode | ~12 |
| `Compiler.Reporting.Render.Type.Localizer` L→Localizer | ~12 |
| `Compiler.Parse.Module` →Module | ~10 |
| `Compiler.Elm.Constraint` C→Con | ~8 |
| `Compiler.Reporting.Render.Type` RT→RenderType | ~8 |
| `Compiler.Elm.Compiler.Type` T/Type→CompType | ~5 |
| `Compiler.Elm.Kernel` K→Kernel | ~4 |
| `Compiler.Reporting.Warning` W→Warning | ~4 |
| `Compiler.Data.Name` N→Name | ~3 |
| All other modules | ~15 |
| **Total** | **~230 file edits** (many files overlap) |

Nearly all changes are mechanical import alias + qualified-name renames, handled by elm-review's auto-fix. The `Data.Map` bare-import changes and `Dict` alias cleanups (3 files) need manual attention.
