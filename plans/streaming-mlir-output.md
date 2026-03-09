# Streaming MLIR Output for CLI Stage-5

## Goal

Reduce peak memory during self-compilation by streaming MLIR text to disk
chunk-by-chunk instead of building one giant `MlirModule` + one huge `String`.
The streaming path is used **only** by the `make --output=…mlir` CLI; existing
tests and non-CLI paths remain unchanged.

## Design Decisions (resolved)

1. **Handle-based write**: Use `hWriteString : Handle -> String -> Task Never ()`
   added to `Eco.File` (XHR + kernel variants + JS handler).
2. **Op ordering**: Downstream MLIR passes don't depend on textual op order.
   Streaming emits nodes first, then lambdas/main/kernels/type-table.
3. **Task chaining**: Use foldl-based Task chain (one `Task.andThen` per node).

---

## Implementation Steps

### Step 1: Add `hWriteString` primitive

Add a handle-based string write operation to the IO layer.

**Files:**

#### 1a. `compiler/src-xhr/Eco/File.elm`
- Add to exposing list: `hWriteString`
- Add function:
  ```elm
  hWriteString : Handle -> String -> Task Never ()
  hWriteString (Handle h) content =
      Eco.XHR.unitTask "File.hWriteString"
          (Encode.object
              [ ( "handle", Encode.int h )
              , ( "content", Encode.string content )
              ]
          )
  ```

#### 1b. `compiler/build-kernel/src-kernel/Eco/File.elm`
- Add to exposing list: `hWriteString`
- Add function:
  ```elm
  hWriteString : Handle -> String -> Task Never ()
  hWriteString (Handle h) content =
      Eco.Kernel.File.hWriteString h content
  ```
  (The kernel JS implementation will need a corresponding function, but that's
  part of eco-kernel-cpp and may already exist or need a stub.)

#### 1c. `compiler/bin/eco-io-handler.js`
- Add handler case in the XHR switch:
  ```js
  case "File.hWriteString": {
      try {
          fs.writeSync(args.handle, args.content, null, "utf8");
          respond(200, "");
      } catch (e) {
          respond(500, JSON.stringify({ error: e.message }));
      }
      break;
  }
  ```

---

### Step 2: Add streaming file-write helper to `Builder.File`

**File: `compiler/src/Builder/File.elm`**

- Add to exposing list: `withStreamingWriter`
- Add import: `import Eco.File as EcoFile`
- Add function:
  ```elm
  withStreamingWriter :
      FilePath
      -> ((String -> Task Never ()) -> Task Never a)
      -> Task Never a
  withStreamingWriter path callback =
      EcoFile.open path EcoFile.WriteMode
          |> Task.andThen
              (\handle ->
                  callback (EcoFile.hWriteString handle)
                      |> Task.andThen
                          (\result ->
                              EcoFile.close handle
                                  |> Task.map (\_ -> result)
                          )
              )
  ```

  This opens the file in write mode, passes a `writeChunk : String -> Task Never ()`
  to the callback, and ensures the handle is closed after.

---

### Step 3: Add streaming helpers to `Mlir.Pretty`

**File: `compiler/src/Mlir/Pretty.elm`**

- Update exposing list: add `ppModuleHeader`, `ppModuleFooter`, `ppTopLevelOp`
- Refactor `ppModule` to use the new helpers (keeps behavior identical):

```elm
ppModuleHeader : String
ppModuleHeader =
    "module {\n"


ppModuleFooter : Loc -> String
ppModuleFooter loc =
    "}"
        ++ " "
        ++ ppLoc loc
        ++ "\n"


ppTopLevelOp : MlirOp -> String
ppTopLevelOp op =
    ppOp 1 Dict.empty op


ppModule : MlirModule -> String
ppModule m =
    let
        header =
            ppModuleHeader

        bodyStr =
            m.body
                |> List.map ppTopLevelOp
                |> String.concat

        footer =
            ppModuleFooter m.loc
    in
    header ++ bodyStr ++ footer
```

`ppModuleHeader` takes no args (it's always `"module {\n"`).
`ppModuleFooter` takes a `Loc` (currently `ppLoc` returns `""` so footer is `"} \n"`).

---

### Step 4: Add streaming generator to `Compiler.Generate.MLIR.Backend`

**File: `compiler/src/Compiler/Generate/MLIR/Backend.elm`**

- Update exposing list: add `streamMlirToWriter`
- Add import: `import Task exposing (Task)`
- Leave `backend` and `generateMlirModule` unchanged.
- Add new function:

```elm
streamMlirToWriter :
    Mode.Mode
    -> Mono.MonoGraph
    -> (String -> Task Never ())
    -> Task Never ()
streamMlirToWriter mode monoGraph0 writeChunk =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes }) =
            monoGraph0

        signatures =
            Ctx.buildSignatures nodes

        ctx =
            Ctx.initContext mode registry signatures ctorShapes
    in
    -- 1. Header
    writeChunk Pretty.ppModuleHeader
        |> Task.andThen (\_ -> streamNodes ctx nodes writeChunk)
        |> Task.andThen
            (\ctxAfterNodes ->
                -- 2. Lambdas
                let
                    ( lambdaOps, finalCtx ) =
                        Lambdas.processLambdas ctxAfterNodes
                in
                writeOps lambdaOps writeChunk
                    |> Task.andThen (\_ ->
                        -- 3. Main
                        let
                            mainOps =
                                case main of
                                    Just mainInfo ->
                                        Functions.generateMainEntry finalCtx mainInfo
                                    Nothing ->
                                        []
                        in
                        writeOps mainOps writeChunk
                            |> Task.andThen (\_ ->
                                -- 4. Kernel decls
                                let
                                    ( kernelDeclOps, _ ) =
                                        Dict.foldl
                                            (\name sig ( accOps, accCtx ) ->
                                                let
                                                    ( newCtx, declOp ) =
                                                        Functions.generateKernelDecl accCtx name sig
                                                in
                                                ( declOp :: accOps, newCtx )
                                            )
                                            ( [], finalCtx )
                                            finalCtx.kernelDecls
                                in
                                writeOps (List.reverse kernelDeclOps) writeChunk
                                    |> Task.andThen (\_ ->
                                        -- 5. Type table
                                        let
                                            typeTableOp =
                                                TypeTable.generateTypeTable finalCtx
                                        in
                                        writeOps [ typeTableOp ] writeChunk
                                    )
                            )
                    )
                    |> Task.andThen (\_ ->
                        -- 6. Footer
                        writeChunk (Pretty.ppModuleFooter Loc.unknown)
                    )
            )
```

With helpers:

```elm
streamNodes :
    Ctx.Context
    -> EveryDict.Map Int Mono.MonoNode
    -> (String -> Task Never ())
    -> Task Never Ctx.Context
streamNodes ctx0 nodes writeChunk =
    EveryDict.foldl compare
        (\specId node accTask ->
            accTask
                |> Task.andThen
                    (\accCtx ->
                        let
                            ( nodeOps, newCtx ) =
                                Functions.generateNode accCtx specId node
                        in
                        writeOps nodeOps writeChunk
                            |> Task.map (\_ -> newCtx)
                    )
        )
        (Task.succeed ctx0)
        nodes


writeOps : List MlirOp -> (String -> Task Never ()) -> Task Never ()
writeOps ops writeChunk =
    case ops of
        [] ->
            Task.succeed ()
        _ ->
            writeChunk (ops |> List.map Pretty.ppTopLevelOp |> String.concat)
```

**Note on op ordering**: The streaming path emits ops in a different textual
order than `generateMlirModule` (nodes first, then lambdas/main/kernels/type-table
instead of type-table/kernels/lambdas/nodes/main). This is fine because the
downstream MLIR pipeline parses the module as a whole and doesn't depend on
op order within the module body.

---

### Step 5: Split `monoDev` to expose `buildMonoGraph` in `Builder.Generate`

**File: `compiler/src/Builder/Generate.elm`**

- Add to exposing list: `buildMonoGraph`
- Extract from `generateMonoDevOutput` a function that returns just the
  `MonoGraph` + `Mode`:

```elm
type alias MonoBuildResult =
    { monoGraph : Mono.MonoGraph
    , mode : Mode.Mode
    }


buildMonoGraph :
    Bool -> Int -> FilePath -> Maybe String
    -> Maybe ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> Task Exit.Generate MonoBuildResult
buildMonoGraph withSourceMaps leadingLines root maybeBuildDir maybeLocal details (Build.Artifacts artifacts) =
    loadTypedObjects root maybeBuildDir maybeLocal details artifacts.modules
        |> Task.andThen finalizeTypedObjects
        |> Task.andThen
            (\objects ->
                let
                    typedGraph =
                        List.foldl addRootTypedGraph (typedObjectsToGlobalGraph objects) (NE.toList artifacts.roots)

                    globalTypeEnv =
                        List.foldl addRootTypeEnv (typedObjectsToGlobalTypeEnv objects) (NE.toList artifacts.roots)
                in
                Task.succeed ( typedGraph, globalTypeEnv )
                    |> Task.andThen
                        (\( tGraph, typeEnv ) ->
                            case Monomorphize.monomorphize "main" typeEnv tGraph of
                                Err err ->
                                    Task.throw (Exit.GenerateMonomorphizationError err)

                                Ok monoGraph0 ->
                                    Task.succeed monoGraph0
                        )
                    |> Task.andThen
                        (\monoGraph0 ->
                            let
                                monoGraph =
                                    MonoGlobalOptimize.globalOptimize monoGraph0
                            in
                            Task.succeed
                                { monoGraph = monoGraph
                                , mode = Mode.Dev Nothing
                                }
                        )
            )
```

Then rewrite `monoDev` to use `buildMonoGraph`:

```elm
monoDev backend withSourceMaps leadingLines root maybeBuildDir maybeLocal details artifacts =
    buildMonoGraph withSourceMaps leadingLines root maybeBuildDir maybeLocal details artifacts
        |> Task.andThen
            (\{ monoGraph, mode } ->
                prepareSourceMaps withSourceMaps root
                    |> Task.map (generateMonoOutput backend leadingLines mode monoGraph)
            )
```

---

### Step 6: Add `writeMonoMlirStreaming` to `Builder.Generate`

**File: `compiler/src/Builder/Generate.elm`**

- Add to exposing list: `writeMonoMlirStreaming`
- Add imports: `import Builder.File as File`, `import Compiler.Generate.MLIR.Backend as MLIRBackend`

```elm
writeMonoMlirStreaming :
    Bool -> Int -> FilePath -> Maybe String
    -> Maybe ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> FilePath
    -> Task Exit.Generate ()
writeMonoMlirStreaming withSourceMaps leadingLines root maybeBuildDir maybeLocal details artifacts target =
    buildMonoGraph withSourceMaps leadingLines root maybeBuildDir maybeLocal details artifacts
        |> Task.andThen
            (\{ monoGraph, mode } ->
                File.withStreamingWriter target
                    (\writeChunk ->
                        MLIRBackend.streamMlirToWriter mode monoGraph writeChunk
                    )
                    |> Task.mapError never
            )
```

**`Task Never a` → `Task x a` bridging**: `File.withStreamingWriter` returns
`Task Never a`. We use `Task.mapError never` (Elm's built-in `never : Never -> a`)
to lift it into the `Task Exit.Generate ()` space. The `never` function is total
because `Never` has no constructors — the mapped function is never actually called.

---

### Step 7: Update `Terminal.Make.handleMlirOutput` to use streaming

**File: `compiler/src/Terminal/Make.elm`**

Replace:
```elm
handleMlirOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            let
                rootNames =
                    Build.getRootNames artifacts
                style =
                    ctx.style
            in
            toMonoBuilder Generate.mlirBackend ctx.withSourceMaps 0 ctx.root ctx.maybeBuildDir ctx.localPackage ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate style target builder rootNames)
        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)
```

With:
```elm
handleMlirOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            let
                rootNames =
                    Build.getRootNames artifacts
            in
            Task.io
                (Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target))
                |> Task.andThen
                    (\_ ->
                        Generate.writeMonoMlirStreaming
                            ctx.withSourceMaps
                            0
                            ctx.root
                            ctx.maybeBuildDir
                            ctx.localPackage
                            ctx.details
                            artifacts
                            target
                            |> Task.mapError Exit.MakeBadGenerate
                    )
                |> Task.andThen
                    (\_ ->
                        Task.io (Reporting.reportGenerate ctx.style rootNames target)
                    )

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)
```

Key changes:
- No `toMonoBuilder`, no `builder : String`, no `generate style target builder rootNames`.
- We still create the output directory.
- `Reporting.reportGenerate` is called after streaming completes (preserves existing UX).

---

## Summary of files changed

| File | Change |
|------|--------|
| `compiler/src-xhr/Eco/File.elm` | Add `hWriteString` |
| `compiler/build-kernel/src-kernel/Eco/File.elm` | Add `hWriteString` |
| `compiler/bin/eco-io-handler.js` | Add `File.hWriteString` handler |
| `compiler/src/Builder/File.elm` | Add `withStreamingWriter` |
| `compiler/src/Mlir/Pretty.elm` | Add `ppModuleHeader`, `ppModuleFooter`, `ppTopLevelOp`; refactor `ppModule` |
| `compiler/src/Compiler/Generate/MLIR/Backend.elm` | Add `streamMlirToWriter`, `streamNodes`, `writeOps` |
| `compiler/src/Builder/Generate.elm` | Add `MonoBuildResult`, `buildMonoGraph`, `writeMonoMlirStreaming`; refactor `monoDev` |
| `compiler/src/Terminal/Make.elm` | Replace `handleMlirOutput` to use streaming |

## What stays unchanged

- `backend : CodeGen.MonoCodeGen` — pure, used by tests
- `generateMlirModule : Mode.Mode -> Mono.MonoGraph -> MlirModule` — pure, used by invariant tests
- `generateProgram` — pure, uses `ppModule`
- `Generate.monoDev` — still works as before (delegates to `buildMonoGraph` + backend)
- `toMonoBuilder` — still exists and works for JS/HTML paths
- All invariant tests and elm-test-rs tests

## Memory impact

Before: The entire `List MlirOp` (all nodes + lambdas + main + kernels + type table) and its pretty-printed `String` are alive simultaneously.

After (CLI path): Only one node's `List MlirOp` and its `String` chunk are alive at a time. The `Ctx.Context` (which grows as nodes are processed due to `kernelDecls` accumulation) is the only long-lived allocation besides the `MonoGraph` itself.
