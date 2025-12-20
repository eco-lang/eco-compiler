# Plan: Show Full Compilation Errors for Package Dependencies

## Problem Statement

When a package fails to compile, the user sees a generic error:

```
-- PROBLEM BUILDING DEPENDENCIES -----------------------------------------------

I ran into a compilation error when trying to build the following package:

    elm/core 1.0.5

This probably means it has package constraints that are too wide...
```

The actual compilation error (type errors, syntax errors, etc.) is discarded in `Details.elm` and never shown.

## Root Cause

In `/work/compiler/src/Builder/Elm/Details.elm`, lines 1414-1418 and 1435-1439:

```elm
handleCompileResult : Pkg.Name -> DocsStatus -> Result e Compile.Artifacts -> Maybe DResult
handleCompileResult pkg docsStatus result =
    case result of
        Err _ ->           -- ← ERROR DISCARDED
            Nothing
        Ok ... -> ...

handleTypedCompileResult : Pkg.Name -> DocsStatus -> Result e Compile.TypedArtifacts -> Maybe DResult
handleTypedCompileResult pkg docsStatus result =
    case result of
        Err _ ->           -- ← ERROR DISCARDED
            Nothing
        Ok ... -> ...
```

The `e` type parameter contains `Compiler.Reporting.Error.Error` - the same error type used for local modules which gets fully pretty-printed.

## Solution Overview

1. Change `Maybe DResult` to `Result Error.Module DResult` to preserve errors
2. Collect all package compilation errors
3. Display them using the same `Error.toDoc` formatting as local modules
4. Append a note clarifying these are package errors, not local code

## Detailed Changes

### Step 1: Change Result Types

**File:** `Builder/Elm/Details.elm`

Change the compile result handling to preserve errors:

```elm
-- Before:
compile : ... -> Task Never (Maybe DResult)

-- After:
compile : ... -> Task Never (Result Error.Module DResult)
```

Also update:
- `handleCompileResult` signature and body
- `handleTypedCompileResult` signature and body
- All intermediate types that use `Maybe DResult`

### Step 2: Update handleCompileResult Functions

```elm
-- Before:
handleCompileResult : Pkg.Name -> DocsStatus -> Result e Compile.Artifacts -> Maybe DResult
handleCompileResult pkg docsStatus result =
    case result of
        Err _ -> Nothing
        Ok ... -> Just ...

-- After:
handleCompileResult : Pkg.Name -> String -> String -> DocsStatus -> Result Error.Error Compile.Artifacts -> Result Error.Module DResult
handleCompileResult pkg path source docsStatus result =
    case result of
        Err err ->
            Err (Error.Module moduleName path dummyTime source err)
        Ok ... ->
            Ok ...
```

We need to pass additional context:
- `path`: The file path (construct from `Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/src/" ++ moduleNameToPath name`)
- `source`: The source code (available from `Src.Module`)

### Step 3: Update compile Function

The `compile` function needs to pass through the module context:

```elm
compile : Pkg.Name -> Bool -> String -> MVar ... -> Status -> Task Never (Result Error.Module DResult)
compile pkg needsTypedOpt pkgSrcDir mvar status =
    case status of
        SLocal docsStatus deps modul ->
            let
                name = Src.getName modul
                path = pkgSrcDir ++ "/" ++ moduleNameToPath name ++ ".elm"
                source = ... -- extract from modul
            in
            ...
            Compile.compile pkg ifaces modul
                |> Task.map (handleCompileResult pkg path source docsStatus)
```

### Step 4: Collect Errors in writePackageArtifacts

```elm
-- Before:
writePackageArtifacts : ... -> Dict String ModuleName.Raw (Maybe DResult) -> Task Never Dep

-- After:
writePackageArtifacts : ... -> Dict String ModuleName.Raw (Result Error.Module DResult) -> Task Never Dep
writePackageArtifacts ctx exposedDict docsStatus results =
    let
        ( errors, successes ) = partitionResults results
    in
    case errors of
        [] ->
            -- All succeeded, write artifacts
            ...

        err :: errs ->
            -- Report errors, then report broken
            reportPackageCompileErrors ctx.pkg ctx.vsn (err :: errs)
```

### Step 5: Create Error Reporting Function

```elm
reportPackageCompileErrors : Pkg.Name -> V.Version -> List Error.Module -> Task Never Dep
reportPackageCompileErrors pkg vsn errors =
    let
        -- Format errors using same logic as local modules
        errorDoc = Error.toDoc pkgRoot (head errors) (tail errors)

        -- Add package context footer
        footer = D.vcat
            [ D.empty
            , D.dullyellow (D.fromChars "-- NOTE -----------------------------------------------------------------------")
            , D.empty
            , D.reflow ("The errors above occurred while compiling the package: "
                ++ Pkg.toChars pkg ++ " " ++ V.toChars vsn)
            , D.empty
            , D.reflow "This is not an error in your code. The package may have constraints "
                ++ "that are too wide, or there may be a compiler bug."
            ]

        fullDoc = D.vcat [ errorDoc, footer ]
    in
    -- Print the errors
    Reporting.printDoc fullDoc
        |> Task.andThen (\_ -> reportBuildBroken ctx)
```

### Step 6: Update Dep Type (if needed)

If we want to preserve errors in the `Dep` type for better reporting upstream:

```elm
-- Currently:
type alias Dep = Result (Maybe Exit.DetailsBadDep) Artifacts

-- Could become:
type alias Dep = Result DepError Artifacts

type DepError
    = DepBadDep Exit.DetailsBadDep
    | DepCompileErrors (List Error.Module)
```

This allows the error to propagate up and be handled at the top level.

## Files to Modify

| File | Changes |
|------|---------|
| `Builder/Elm/Details.elm` | Main changes: result types, error handling, error display |
| `Builder/Reporting/Exit.elm` | May need new error variant for compile errors with details |

## Chosen Approach: Option C (Lazy File Reading)

Read files **only when there are errors to report**. This avoids storing path/source during crawl, and avoids the cost of reading files that compile successfully.

### Key Insight

The compile phase has access to:
- `ctx` (BuildContext) which contains `cache`, `pkg`, `vsn`
- `modul` (Src.Module) which has:
  - Module name via `Src.getName`
  - Syntax version via `data.syntaxVersion` (where `Src.Module data = modul`)

The syntax version determines the file extension:
- `SV.Elm` → `.elm`
- `SV.Guida` → `.guida`

From these, we can construct the file path:
```elm
let
    name = Src.getName modul
    (Src.Module data) = modul
    extension = case data.syntaxVersion of
        SV.Elm -> ".elm"
        SV.Guida -> ".guida"
in
Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/src/" ++ ModuleName.toFilePath name ++ extension
```

### Implementation Details

#### Change 1: `handleCompileResult` becomes effectful

```elm
-- Before (pure):
handleCompileResult : Pkg.Name -> DocsStatus -> Result e Compile.Artifacts -> Maybe DResult

-- After (effectful, reads file on error):
handleCompileResult : BuildContext -> Src.Module -> DocsStatus -> Result Error.Error Compile.Artifacts -> Task Never (Result Error.Module DResult)
handleCompileResult ctx modul docsStatus result =
    case result of
        Err err ->
            let
                name = Src.getName modul
                (Src.Module data) = modul
                extension = case data.syntaxVersion of
                    SV.Elm -> ".elm"
                    SV.Guida -> ".guida"
                path = Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/src/" ++ ModuleName.toFilePath name ++ extension
            in
            Task.map2
                (\time source -> Err { name = name, absolutePath = path, modificationTime = time, source = source, error = err })
                (File.getTime path)
                (File.readUtf8 path)

        Ok (Compile.Artifacts canonical annotations objects) ->
            Task.succeed (Ok (RLocal (I.fromModule ctx.pkg canonical annotations) objects Nothing (makeDocs docsStatus canonical)))
```

Note: `Error.Module` is a type alias for a record, so we construct it with record syntax.

#### Change 1b: `handleTypedCompileResult` (same pattern)

```elm
-- Before (pure):
handleTypedCompileResult : Pkg.Name -> DocsStatus -> Result e Compile.TypedArtifacts -> Maybe DResult

-- After (effectful, reads file on error):
handleTypedCompileResult : BuildContext -> Src.Module -> DocsStatus -> Result Error.Error Compile.TypedArtifacts -> Task Never (Result Error.Module DResult)
handleTypedCompileResult ctx modul docsStatus result =
    case result of
        Err err ->
            let
                name = Src.getName modul
                (Src.Module data) = modul
                extension = case data.syntaxVersion of
                    SV.Elm -> ".elm"
                    SV.Guida -> ".guida"
                path = Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/src/" ++ ModuleName.toFilePath name ++ extension
            in
            Task.map2
                (\time source -> Err { name = name, absolutePath = path, modificationTime = time, source = source, error = err })
                (File.getTime path)
                (File.readUtf8 path)

        Ok (Compile.TypedArtifacts typedData) ->
            Task.succeed (Ok (RLocal (I.fromModule ctx.pkg typedData.canonical typedData.annotations) typedData.objects (Just typedData.typedObjects) (makeDocs docsStatus typedData.canonical)))
```

#### Change 2: `compile` passes ctx and modul

```elm
compile : BuildContext -> MVar ... -> Status -> Task Never (Result Error.Module DResult)
compile ctx mvar status =
    case status of
        SLocal docsStatus deps modul ->
            ...
            if ctx.needsTypedOpt then
                Compile.compileTyped ctx.pkg ifaces modul
                    |> Task.andThen (handleTypedCompileResult ctx modul docsStatus)
            else
                Compile.compile ctx.pkg ifaces modul
                    |> Task.andThen (handleCompileResult ctx modul docsStatus)

        SForeign iface ->
            Task.succeed (Ok (RForeign iface))

        SKernelLocal chunks ->
            Task.succeed (Ok (RKernelLocal chunks))

        SKernelForeign ->
            Task.succeed (Ok RKernelForeign)
```

#### Change 3: Update call site in `forkCompileModules`

```elm
-- Before:
Utils.mapTraverse ... (compile ctx.pkg ctx.needsTypedOpt rmvar) statuses

-- After:
Utils.mapTraverse ... (compile ctx rmvar) statuses
```

#### Change 4: `writePackageArtifacts` handles errors

```elm
writePackageArtifacts : BuildContext -> Dict ... -> DocsStatus -> Dict String ModuleName.Raw (Result Error.Module DResult) -> Task Never Dep
writePackageArtifacts ctx exposedDict docsStatus results =
    let
        (errors, successes) = partitionResults results
    in
    case errors of
        [] ->
            -- All succeeded, continue with current logic using successes
            ...

        firstErr :: restErrs ->
            -- Print errors, then report broken
            printPackageCompileErrors ctx.pkg ctx.vsn firstErr restErrs
                |> Task.andThen (\_ -> reportBuildBroken ctx)
```

#### Change 5: Error printing function

Using the existing error reporting infrastructure:

```elm
printPackageCompileErrors : Stuff.PackageCache -> Pkg.Name -> V.Version -> Error.Module -> List Error.Module -> Task Never ()
printPackageCompileErrors cache pkg vsn firstErr restErrs =
    let
        -- The root path for rendering error locations
        pkgRoot = Stuff.package cache pkg vsn ++ "/src"

        -- Create the standard compiler error report
        errorDoc = Error.toDoc pkgRoot firstErr restErrs

        -- Add package context footer
        footer = D.vcat
            [ D.empty
            , D.dullyellow (D.fromChars "-- NOTE -----------------------------------------------------------------------")
            , D.empty
            , D.reflow ("The errors above occurred while compiling package: " ++ Pkg.toChars pkg ++ " " ++ V.toChars vsn)
            , D.reflow "This is not an error in your code."
            ]

        fullDoc = D.vcat [ errorDoc, footer ]
    in
    -- Print using existing Help.toStderr mechanism
    Help.toStderr fullDoc
```

Alternative using existing `compilerReport`:
```elm
printPackageCompileErrors cache pkg vsn firstErr restErrs =
    let
        pkgRoot = Stuff.package cache pkg vsn ++ "/src"
        report = Help.compilerReport pkgRoot firstErr restErrs
        errorDoc = Help.reportToDoc report
        -- ... add footer and print
    in
    Help.toStderr fullDoc
```

### Helper: partitionResults

```elm
partitionResults : Dict String k (Result err ok) -> (List err, Dict String k ok)
partitionResults dict =
    Dict.foldl
        (\k result (errs, oks) ->
            case result of
                Err e -> (e :: errs, oks)
                Ok v -> (errs, Dict.insert k v oks)
        )
        ([], Dict.empty)
        dict
```

## Compiler Flag: `-Xpackage-errors`

This feature is gated behind an experimental flag. By default, the current behavior (generic error message) remains. Only when `-Xpackage-errors` is passed will the full package compilation errors be displayed.

### Flag Flow

1. **Terminal/Make.elm**: Add flag to `FlagsData` and parse it
2. **Details.load**: Accept the flag as a parameter
3. **EnvData/BuildContext**: Store the flag
4. **writePackageArtifacts**: Check flag before printing detailed errors

### Change 6: Add flag to Terminal/Make.elm

```elm
-- FlagsData (add new field):
type alias FlagsData =
    { debug : Bool
    , optimize : Bool
    , withSourceMaps : Bool
    , output : Maybe Output
    , report : Maybe ReportType
    , docs : Maybe String
    , showPackageErrors : Bool  -- NEW
    }
```

The flag is parsed in `Terminal/Main.elm` where command-line arguments are processed.

### Change 7: Update Details.load signature

```elm
-- Before:
load : Reporting.Style -> BW.Scope -> FilePath -> Bool -> Task Never (Result Exit.Details Details)
load style scope root needsTypedOpt = ...

-- After:
load : Reporting.Style -> BW.Scope -> FilePath -> Bool -> Bool -> Task Never (Result Exit.Details Details)
load style scope root needsTypedOpt showPackageErrors = ...
```

### Change 8: Store flag in EnvData

```elm
type alias EnvData =
    { key : Reporting.DKey
    , scope : BW.Scope
    , root : FilePath
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , connection : Solver.Connection
    , registry : Registry.Registry
    , needsTypedOpt : Bool
    , showPackageErrors : Bool  -- NEW
    }
```

### Change 9: Store flag in BuildContext

```elm
type alias BuildContext =
    { key : Reporting.DKey
    , cache : Stuff.PackageCache
    , pkg : Pkg.Name
    , vsn : V.Version
    , fingerprint : Fingerprint
    , fingerprints : EverySet ... Fingerprint
    , needsTypedOpt : Bool
    , showPackageErrors : Bool  -- NEW
    }
```

### Change 10: Conditional error printing in writePackageArtifacts

```elm
writePackageArtifacts ctx exposedDict docsStatus results =
    let
        (errors, successes) = partitionResults results
    in
    case errors of
        [] ->
            -- All succeeded, continue with current logic
            ...

        firstErr :: restErrs ->
            if ctx.showPackageErrors then
                -- Print detailed errors, then report broken
                printPackageCompileErrors ctx.cache ctx.pkg ctx.vsn firstErr restErrs
                    |> Task.andThen (\_ -> reportBuildBroken ctx)
            else
                -- Default behavior: just report broken (no detailed errors)
                reportBuildBroken ctx
```

### Update all call sites of Details.load

All existing call sites pass `False` for the new parameter (maintaining current behavior):

| File | Change |
|------|--------|
| `Terminal/Make.elm` | Pass `flagsData.showPackageErrors` |
| `Terminal/Test.elm` | Pass `False` |
| `Terminal/Repl.elm` | Pass `False` |
| `Terminal/Publish.elm` | Pass `False` |
| `Terminal/Bump.elm` | Pass `False` |
| `Terminal/Diff.elm` | Pass `False` |
| `API/Make.elm` | Pass `False` |

## Files to Modify

| File | Changes |
|------|---------|
| `Terminal/Make.elm` | Add `showPackageErrors` to `FlagsData`, pass to `Details.load` |
| `Terminal/Main.elm` | Parse `-Xpackage-errors` flag |
| `Builder/Elm/Details.elm` | Update `load` signature, `EnvData`, `BuildContext`, conditional printing in `writePackageArtifacts`, `handleCompileResult`, `handleTypedCompileResult`, `compile`, `forkCompileModules`, new `printPackageCompileErrors` |
| `Terminal/Test.elm` | Update `Details.load` call (pass `False`) |
| `Terminal/Repl.elm` | Update `Details.load` call (pass `False`) |
| `Terminal/Publish.elm` | Update `Details.load` calls (pass `False`) |
| `Terminal/Bump.elm` | Update `Details.load` call (pass `False`) |
| `Terminal/Diff.elm` | Update `Details.load` call (pass `False`) |
| `API/Make.elm` | Update `Details.load` call (pass `False`) |

## Imports to Add

```elm
import Builder.File as File
import Builder.Reporting.Exit.Help as Help
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Parse.SyntaxVersion as SV
import Compiler.Reporting.Error as Error
import Compiler.Reporting.Doc as D  -- if not already imported
```

## Multiple Packages

If multiple packages fail, each package's errors will be printed with its own package context footer, keeping errors grouped by package.

## Testing

After implementation:
1. Introduce a deliberate type error in `elm/core` or a test package
2. Run `guida make` on a project that depends on it
3. Verify the full error is displayed with file path, line numbers, and code snippets
4. Verify the package context footer appears after the errors

## Expected Output

```
-- TYPE MISMATCH ---------------------------------------------- elm/core/src/List.elm

The 2nd argument to `map` is not what I expect:

45|     List.map f xs
                   ^^
This `xs` value is a:

    String

But `map` needs the 2nd argument to be:

    List a

-- NOTE -----------------------------------------------------------------------

The errors above occurred while compiling the package: elm/core 1.0.5

This is not an error in your code. The package may have constraints that are
too wide, or there may be a compiler bug.
```
