# MLIR Output Flag Analysis

## Overview
The Eco compiler supports MLIR output generation via the `--output` flag. When a file with `.mlir` extension is specified, the compiler automatically activates monomorphization and the MLIR backend.

## Flag Parsing
**Location**: `/work/compiler/src/Terminal/Make.elm`

### Output Flag Definition (lines 506-535)
```elm
{-| Parser definition for output file command-line arguments. -}
output : Parser
output =
    Parser
        { singular = "output file"
        , plural = "output files"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "elm.js", "index.html", "output.mlir", "/dev/null" ]
        }

{-| Parse a string into an Output value based on file extension. -}
parseOutput : String -> Maybe Output
parseOutput name =
    if isDevNull name then
        Just DevNull
    else if hasExt ".html" name then
        Just (Html name)
    else if hasExt ".js" name then
        Just (JS name)
    else if hasExt ".mlir" name then
        Just (MLIR name)
    else
        Nothing
```

### Output Type Definition (lines 94-100)
```elm
{-| Output format and destination for the compiled code. -}
type Output
    = JS String
    | Html String
    | MLIR String
    | DevNull
```

## Build Pipeline Integration
**Location**: `/work/compiler/src/Terminal/Make.elm` (lines 268-277)

### MLIR Output Handler
```elm
handleMlirOutput : BuildContext -> FilePath -> Build.Artifacts -> Task Exit.Make ()
handleMlirOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            toMonoBuilder Generate.mlirBackend ctx.withSourceMaps 0 ctx.root ctx.maybeBuildDir ctx.localPackage ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate ctx.style target builder (Build.getRootNames artifacts))

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)
```

### Typed Optimization Flag (lines 196-203)
When MLIR output is selected, typed optimization is automatically enabled:
```elm
shouldUseTypedOpt : Maybe Output -> Bool
shouldUseTypedOpt maybeOutput =
    case maybeOutput of
        Just (MLIR _) ->
            True
        _ ->
            False
```

## Code Generation Pipeline
**Location**: `/work/compiler/src/Builder/Generate.elm`

### MLIR Backend Definition (lines 88-92)
```elm
{-| MLIR code generation backend for monomorphized programs. -}
mlirBackend : CodeGen.MonoCodeGen
mlirBackend =
    MLIR.backend
```

### Monomorphization Entry Point (lines 585-589)
```elm
{-| Generates monomorphized output for MLIR mono backend after specializing polymorphic functions. -}
monoDev : CodeGen.MonoCodeGen -> Bool -> Int -> FilePath -> Maybe String -> Maybe ( Pkg.Name, FilePath ) -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
monoDev backend withSourceMaps leadingLines root maybeBuildDir maybeLocal details (Build.Artifacts artifacts) =
    loadTypedObjects root maybeBuildDir maybeLocal details artifacts.modules
        |> Task.andThen finalizeTypedObjects
        |> Task.andThen (generateMonoDevOutput backend withSourceMaps leadingLines root artifacts.roots)
```

## MLIR Backend Implementation
**Location**: `/work/compiler/src/Compiler/Generate/MLIR/Backend.elm`

### Backend Interface (lines 32-39)
```elm
{-| The MLIR backend that generates MLIR code from fully monomorphized IR with all polymorphism resolved. -}
backend : CodeGen.MonoCodeGen
backend =
    { generate =
        \config ->
            generateProgram config.mode config.typeEnv config.graph |> CodeGen.TextOutput
    }
```

### Code Generation Steps (line 113-115)
1. Takes Mode, TypeEnv.GlobalTypeEnv, and Mono.MonoGraph
2. Calls generateMlirModule to create MlirModule structure
3. Uses Pretty.ppModule to format as string

## Command-Line Usage Examples
**From CMakeLists.txt**:
```bash
eco make --output=file.mlir src/Main.elm
```

**From build.sh**:
```bash
$ELM make --output=$js $elm_entry
```

## Process Flow for MLIR Output

1. **Flag Parsing**: `--output=file.mlir` detected by parseOutput, returns `MLIR "file.mlir"`
2. **Build Decision**: shouldUseTypedOpt detects MLIR output, enables typed optimization
3. **Module Loading**: Load typed artifacts (includes type environment)
4. **Monomorphization**: Convert typed optimized IR to fully monomorphic graph
5. **MLIR Codegen**: 
   - Build function signatures from nodes
   - Generate typed MLIR operations in eco dialect
   - Generate kernel function declarations
   - Format and output as string
6. **File Writing**: Write generated MLIR string to specified output file

## Key Requirements for MLIR Output

- **No main functions required**: Unlike JavaScript, MLIR output doesn't require exported main functions
- **Typed artifact loading**: Requires `.ecot` files (TypedModuleArtifact binary format)
- **Global type environment**: Must track all type definitions across modules
- **Constructor shape information**: MonoGraph includes ctorShapes for memory layout
- **Kernel package support**: Can reference kernel functions via --kernel-package flag
- **Local package mapping**: Supports --local-package for resolved dependencies

## Monomorphization Details
**Location**: `/work/compiler/src/Compiler/Monomorphize/Monomorphize.elm`

The monomorphization phase:
- Takes entry point name and global type environment
- Specializes all polymorphic functions to concrete types
- Resolves all type variables based on call sites
- Returns MonoGraph with:
  - nodes: specialized function definitions
  - main: optional entry point
  - registry: all type definitions
  - ctorShapes: memory layout for custom types
