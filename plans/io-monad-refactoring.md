# IO Monad Refactoring Plan

**STATUS: SHELVED** - Blocked on prerequisite work (Bytes over Ports)

## Executive Summary

This plan details the refactoring of Guida's IO system from HTTP-intercepted Tasks to a Free Monad-based IO type with a port-based interpreter. The goal is to preserve the existing monadic API while enabling clean port-based communication with JavaScript.

**Blocking Prerequisite:** Standard Elm ports do not support `Bytes.Bytes`. The compiler extensively uses binary-encoded data for MVar values and file operations. Before this migration can proceed, Elm must be patched to support Bytes over ports (mapping to `Uint8Array` in JavaScript). See [Prerequisite: Bytes Over Ports](#prerequisite-bytes-over-ports).

---

## Part 1: Current System Analysis

### 1.1 Execution Model

**Current**: `Platform.worker` with a trampoline pattern
```elm
-- System/IO.elm
type alias Msg = Task Never ()

update : Msg -> Model -> ( Model, Cmd Msg )
update msg () =
    ( (), Task.perform Task.succeed msg )
```

This creates a synchronous-feeling execution where each Task completes before the next starts.

### 1.2 IO Primitive Operations (Complete List)

From analysis of all `Impure.task` calls:

| Category | Operation | Body Type | Response Type |
|----------|-----------|-----------|---------------|
| **File System** | | | |
| | `read` | StringBody(path) | StringResolver |
| | `writeString` | StringBody(content) + header(path) | Always () |
| | `write` | BytesBody + header(path) | Always () |
| | `binaryDecodeFileOrFail` | StringBody(path) | BytesResolver |
| | `dirDoesFileExist` | StringBody(path) | DecoderResolver Bool |
| | `dirDoesDirectoryExist` | StringBody(path) | DecoderResolver Bool |
| | `dirCreateDirectoryIfMissing` | JsonBody{createParents, filename} | Always () |
| | `dirListDirectory` | StringBody(path) | DecoderResolver [String] |
| | `dirRemoveFile` | StringBody(path) | Always () |
| | `dirRemoveDirectoryRecursive` | StringBody(path) | Always () |
| | `dirCanonicalizePath` | StringBody(path) | StringResolver |
| | `dirGetCurrentDirectory` | EmptyBody | StringResolver |
| | `dirGetAppUserDataDirectory` | StringBody(appName) | StringResolver |
| | `dirGetModificationTime` | StringBody(path) | DecoderResolver Int |
| | `dirFindExecutable` | StringBody(name) | DecoderResolver (Maybe String) |
| | `lockFile` | StringBody(path) | Always () |
| | `unlockFile` | StringBody(path) | Always () |
| | `withFile` | StringBody(path) + header(mode) | DecoderResolver Int (handle) |
| | `hClose` | StringBody(handle) | Always () |
| | `hFileSize` | StringBody(handle) | DecoderResolver Int |
| **Console** | | | |
| | `hPutStr` | StringBody(content) + header(fd) | Always () |
| | `getLine` | EmptyBody | StringResolver |
| | `replGetInputLine` | StringBody(prompt) | DecoderResolver (Maybe String) |
| | `readStdin` | EmptyBody | StringResolver |
| **Process/Environment** | | | |
| | `envLookupEnv` | StringBody(name) | DecoderResolver (Maybe String) |
| | `envGetArgs` | EmptyBody | DecoderResolver [String] |
| | `getArgs` (API) | EmptyBody | DecoderResolver Args |
| | `exitWith` | StringBody(code) | Crash |
| | `exitWithResponse` | JsonBody(value) | Crash |
| | `withCreateProcess` | JsonBody(config) | DecoderResolver {stdinHandle, ph} |
| | `waitForProcess` | StringBody(ph) | DecoderResolver Int |
| **Concurrency** | | | |
| | `newEmptyMVar` | EmptyBody | DecoderResolver Int |
| | `readMVar` | StringBody(id) | BytesResolver |
| | `takeMVar` | StringBody(id) | BytesResolver |
| | `putMVar` | BytesBody + header(id) | Always () |
| **Network** | | | |
| | `getArchive` | StringBody(url) | DecoderResolver {sha, archive} |
| | `httpUpload` | JsonBody(config) | DecoderResolver response |
| **State** | | | |
| | `getStateT` | EmptyBody | DecoderResolver ReplState |
| | `putStateT` | JsonBody(state) | Always () |
| **Node** | | | |
| | `nodeGetDirname` | EmptyBody | StringResolver |
| | `nodeMathRandom` | EmptyBody | DecoderResolver Float |
| | `dirWithCurrentDirectory` | StringBody(path) | Always () |

**Total: 38 distinct IO operations**

### 1.3 Task Helper Functions Used

From `Utils/Task/Extra.elm`:
- `pure` / `Task.succeed` - lift value into Task
- `bind` / `Task.andThen` - monadic bind
- `fmap` / `Task.map` - functor map
- `apply` - applicative apply
- `throw` / `Task.fail` - raise error
- `run` - convert `Task x a` to `Task Never (Result x a)`
- `io` - convert `Task Never a` to `Task x a`
- `eio` - unwrap `Task Never (Result x a)` to `Task y a` with error mapping
- `mio` - unwrap `Task Never (Maybe a)` to `Task x a`
- `mapM` - traverse list with Task
- `void` - discard result

### 1.4 Concurrency Patterns

**Fork Pattern** (used in Builder/Build.elm, Builder/Elm/Details.elm, etc.):
```elm
fork : (a -> BE.Encoder) -> Task Never a -> Task Never (MVar a)
fork encoder work =
    Utils.newEmptyMVar
        |> Task.bind (\mvar ->
            Utils.forkIO (Task.bind (Utils.putMVar encoder mvar) work)
                |> Task.fmap (\_ -> mvar))
```

**Key insight**: `forkIO` uses `Process.spawn` which is built into Elm's runtime. This spawns a new "green thread" that runs concurrently.

**Collect Pattern**:
```elm
-- Start multiple tasks, each writes to its own MVar
mvars <- mapM (fork encoder) tasks
-- Wait for all results
results <- mapM readMVar mvars
```

### 1.5 Error Handling Patterns

**Pattern 1: Task x a with throw/run**
```elm
someOperation : Task Exit.Error Result
someOperation =
    doWork
        |> Task.bind (\result ->
            if isValid result then
                Task.pure result
            else
                Task.throw SomeError)

-- At boundary, convert to Task Never (Result x a)
Task.run someOperation
```

**Pattern 2: eio for Result unwrapping**
```elm
Task.eio Exit.MakeBadDetails (Details.load style scope root)
-- Converts Task Never (Result x a) to Task y a
```

**Pattern 3: mio for Maybe unwrapping**
```elm
Task.mio Exit.PublishNoOutline Stuff.findRoot
-- Converts Task Never (Maybe a) to Task x a
```

---

## Part 2: IO Monad Design

### 2.1 Core Type Definition

```elm
module Utils.IO exposing
    ( IO(..)
    , pure, andThen, map, map2, map3, map4, map5
    , sequence, traverse, foldM
    , throw, catch, mapError
    , run, eio, mio, io
    -- Primitives (re-exported from IO.Primitives)
    )

{-| Free Monad representation of IO operations.

This type describes IO computations without executing them.
The interpreter in System.IO converts these to port commands.
-}
type IO x a
    = Pure a
    | Throw x
    | Bind (IO x y) (y -> IO x a)
    | Catch (IO x a) (x -> IO x a)
    | Primitive (Primitive a)


{-| Low-level IO operations that map to ports. -}
type Primitive a
    = -- File System
      ReadFile FilePath (String -> a)
    | WriteFile FilePath String a
    | WriteBinary FilePath Bytes a
    | ReadBinary FilePath (Bytes -> a)
    | DoesFileExist FilePath (Bool -> a)
    | DoesDirectoryExist FilePath (Bool -> a)
    | CreateDirectory Bool FilePath a
    | ListDirectory FilePath (List FilePath -> a)
    | RemoveFile FilePath a
    | RemoveDirectoryRecursive FilePath a
    | CanonicalizePath FilePath (FilePath -> a)
    | GetCurrentDirectory (FilePath -> a)
    | GetAppUserDataDirectory String (FilePath -> a)
    | GetModificationTime FilePath (Time.Posix -> a)
    | FindExecutable String (Maybe FilePath -> a)
    | LockFile FilePath a
    | UnlockFile FilePath a

    -- Console
    | PutStr Int String a  -- fd, content
    | GetLine (String -> a)
    | ReplGetInputLine String (Maybe String -> a)
    | ReadStdin (String -> a)

    -- Environment
    | LookupEnv String (Maybe String -> a)
    | GetArgs (List String -> a)
    | Exit Int  -- Never returns
    | ExitWithResponse Json.Value  -- Never returns

    -- Process
    | WithCreateProcess ProcessConfig (ProcessHandles -> a)
    | WaitForProcess ProcessHandle (ExitCode -> a)

    -- Concurrency
    | NewEmptyMVar (MVar a -> a)
    | ReadMVar (MVar v) (v -> a)
    | TakeMVar (MVar v) (v -> a)
    | PutMVar (MVar v) v a
    | ForkIO (IO Never ()) (ThreadId -> a)

    -- Network
    | GetArchive String (ArchiveResult -> a)
    | HttpUpload UploadConfig (UploadResult -> a)

    -- State (for REPL)
    | GetReplState (ReplState -> a)
    | PutReplState ReplState a

    -- Misc
    | GetDirname (String -> a)
    | MathRandom (Float -> a)
```

### 2.2 Monad Instance

```elm
pure : a -> IO x a
pure a =
    Pure a


andThen : (a -> IO x b) -> IO x a -> IO x b
andThen f io =
    case io of
        Pure a ->
            f a

        Throw x ->
            Throw x

        Bind m g ->
            -- Reassociate to prevent stack growth
            Bind m (\y -> andThen f (g y))

        Catch m handler ->
            Catch (andThen f m) (\x -> andThen f (handler x))

        Primitive prim ->
            Bind (Primitive prim) f


map : (a -> b) -> IO x a -> IO x b
map f io =
    andThen (f >> pure) io


-- Error handling
throw : x -> IO x a
throw x =
    Throw x


catch : (x -> IO x a) -> IO x a -> IO x a
catch handler io =
    Catch io handler


mapError : (x -> y) -> IO x a -> IO y a
mapError f io =
    -- Implementation via catch and throw
    ...
```

### 2.3 Helper Functions (matching Task.Extra)

```elm
-- Convert IO Never a to IO x a
io : IO Never a -> IO x a
io work =
    mapError never work


-- Unwrap Result
eio : (x -> y) -> IO Never (Result x a) -> IO y a
eio f work =
    work
        |> io
        |> andThen (\result ->
            case result of
                Ok a -> pure a
                Err x -> throw (f x))


-- Unwrap Maybe
mio : x -> IO Never (Maybe a) -> IO x a
mio x work =
    work
        |> io
        |> andThen (\maybe ->
            case maybe of
                Just a -> pure a
                Nothing -> throw x)


-- Run with error capture
run : IO x a -> IO Never (Result x a)
run work =
    catch (Err >> pure) (map Ok work)


-- List operations
sequence : List (IO x a) -> IO x (List a)
sequence ios =
    case ios of
        [] -> pure []
        first :: rest ->
            first |> andThen (\a ->
                sequence rest |> map (\as -> a :: as))


traverse : (a -> IO x b) -> List a -> IO x (List b)
traverse f list =
    sequence (List.map f list)


foldM : (b -> a -> IO x b) -> b -> List a -> IO x b
foldM f acc list =
    case list of
        [] -> pure acc
        first :: rest ->
            f acc first |> andThen (\acc2 -> foldM f acc2 rest)
```

### 2.4 Primitive Constructors

```elm
module Utils.IO.Primitives exposing (..)

-- File System
readFile : FilePath -> IO x String
readFile path =
    Primitive (ReadFile path identity)


writeFile : FilePath -> String -> IO x ()
writeFile path content =
    Primitive (WriteFile path content ())


doesFileExist : FilePath -> IO x Bool
doesFileExist path =
    Primitive (DoesFileExist path identity)


-- Console
putStr : String -> IO x ()
putStr content =
    Primitive (PutStr 1 content ())


putStrLn : String -> IO x ()
putStrLn content =
    putStr (content ++ "\n")


hPutStr : Handle -> String -> IO x ()
hPutStr (Handle fd) content =
    Primitive (PutStr fd content ())


-- Concurrency
newEmptyMVar : IO x (MVar a)
newEmptyMVar =
    Primitive (NewEmptyMVar identity)


readMVar : MVar a -> IO x a
readMVar mvar =
    Primitive (ReadMVar mvar identity)


takeMVar : MVar a -> IO x a
takeMVar mvar =
    Primitive (TakeMVar mvar identity)


putMVar : MVar a -> a -> IO x ()
putMVar mvar value =
    Primitive (PutMVar mvar value ())


forkIO : IO Never () -> IO x ThreadId
forkIO work =
    Primitive (ForkIO work identity)
```

---

## Part 3: Interpreter Design

### 3.1 Runtime Model

```elm
module System.IO exposing (Program, run)

type alias Program =
    Platform.Program () Model Msg


type alias Model =
    { pending : Dict String Continuation
    , nextId : Int
    , threads : Dict Int ThreadState  -- For forkIO support
    , mvars : Dict Int MVarState      -- MVar state (mirrors JS)
    }


type Continuation
    = ContString (String -> IO Never ())
    | ContBool (Bool -> IO Never ())
    | ContInt (Int -> IO Never ())
    | ContMaybe (Maybe String -> IO Never ())
    | ContBytes (Bytes -> IO Never ())
    | ContJson (Json.Value -> IO Never ())
    | ContUnit (IO Never ())
    | ContMVar (Int -> IO Never ())
    | ContArchive (ArchiveResult -> IO Never ())
    -- etc.


type Msg
    = PortResponse PortResponseData
    | ThreadComplete Int
    | RunNext


type alias PortResponseData =
    { id : String
    , type_ : String
    , payload : Json.Value
    }
```

### 3.2 Interpreter Loop

```elm
run : IO Never () -> Program
run io =
    Platform.worker
        { init = init io
        , update = update
        , subscriptions = subscriptions
        }


init : IO Never () -> () -> ( Model, Cmd Msg )
init io () =
    step
        { pending = Dict.empty
        , nextId = 0
        , threads = Dict.empty
        , mvars = Dict.empty
        }
        io


step : Model -> IO Never () -> ( Model, Cmd Msg )
step model io =
    case io of
        Pure () ->
            -- Main thread complete
            ( model, Cmd.none )

        Throw x ->
            -- Never type, impossible
            never x

        Bind inner next ->
            stepBind model inner next

        Catch inner handler ->
            -- For IO Never, errors are impossible
            step model inner

        Primitive prim ->
            stepPrimitive model prim (\_ -> Pure ())


stepBind : Model -> IO Never y -> (y -> IO Never ()) -> ( Model, Cmd Msg )
stepBind model inner next =
    case inner of
        Pure y ->
            step model (next y)

        Throw x ->
            never x

        Bind inner2 next2 ->
            -- Reassociate: (m >>= f) >>= g  =>  m >>= (\x -> f x >>= g)
            step model (Bind inner2 (\x -> Bind (next2 x) next))

        Catch inner2 handler ->
            step model (Bind inner2 next)

        Primitive prim ->
            stepPrimitive model prim next


stepPrimitive : Model -> Primitive y -> (y -> IO Never ()) -> ( Model, Cmd Msg )
stepPrimitive model prim next =
    case prim of
        -- Fire-and-forget operations
        PutStr fd content () ->
            ( model
            , Cmd.batch
                [ ports.consoleWrite { fd = fd, content = content }
                , sendSelf RunNext
                ]
            )
            -- Store continuation for RunNext
            |> storeContinuation (ContUnit (next ()))

        -- Call-and-response operations
        ReadFile path toResult ->
            let
                id = String.fromInt model.nextId
                newModel = { model | nextId = model.nextId + 1 }
            in
            ( { newModel | pending = Dict.insert id (ContString (\s -> next (toResult s))) newModel.pending }
            , ports.fsRead { id = id, path = path }
            )

        DoesFileExist path toBool ->
            let
                id = String.fromInt model.nextId
                newModel = { model | nextId = model.nextId + 1 }
            in
            ( { newModel | pending = Dict.insert id (ContBool (\b -> next (toBool b))) newModel.pending }
            , ports.fsDoesFileExist { id = id, path = path }
            )

        -- Concurrency operations
        NewEmptyMVar toMVar ->
            let
                id = String.fromInt model.nextId
                newModel = { model | nextId = model.nextId + 1 }
            in
            ( { newModel | pending = Dict.insert id (ContMVar (\mvarId -> next (toMVar (MVar mvarId)))) newModel.pending }
            , ports.concNewEmptyMVar { id = id }
            )

        ForkIO work toThreadId ->
            -- Fork spawns a new "thread" that runs independently
            let
                threadId = model.nextId
                newModel =
                    { model
                    | nextId = model.nextId + 1
                    , threads = Dict.insert threadId (ThreadRunning work) model.threads
                    }
            in
            -- Continue main thread immediately
            step newModel (next (toThreadId threadId))
            -- The forked thread will be stepped by ThreadComplete messages

        -- Exit operations (never return)
        Exit code ->
            ( model, ports.procExit { code = code } )

        ExitWithResponse value ->
            ( model, ports.procExitWithResponse { response = value } )

        -- ... other primitives


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        PortResponse response ->
            case Dict.get response.id model.pending of
                Just cont ->
                    let
                        newModel = { model | pending = Dict.remove response.id model.pending }
                        nextIO = applyContinuation cont response
                    in
                    step newModel nextIO

                Nothing ->
                    ( model, Cmd.none )

        ThreadComplete threadId ->
            -- A forked thread completed
            ( { model | threads = Dict.remove threadId model.threads }
            , Cmd.none
            )

        RunNext ->
            -- For fire-and-forget operations, continue with stored continuation
            ...


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ ports.fsResponse (PortResponse << decodeResponse)
        , ports.consoleResponse (PortResponse << decodeResponse)
        , ports.procResponse (PortResponse << decodeResponse)
        , ports.concResponse (PortResponse << decodeResponse)
        , ports.netResponse (PortResponse << decodeResponse)
        ]
```

### 3.3 Port Definitions

```elm
port module System.IO.Ports exposing (..)

-- File System (outgoing)
port fsRead : { id : String, path : String } -> Cmd msg
port fsWriteString : { id : String, path : String, content : String } -> Cmd msg
port fsWriteBinary : { id : String, path : String, content : String } -> Cmd msg  -- base64
port fsBinaryDecode : { id : String, path : String } -> Cmd msg
port fsDoesFileExist : { id : String, path : String } -> Cmd msg
port fsDoesDirectoryExist : { id : String, path : String } -> Cmd msg
port fsCreateDirectory : { id : String, path : String, createParents : Bool } -> Cmd msg
port fsListDirectory : { id : String, path : String } -> Cmd msg
port fsRemoveFile : { id : String, path : String } -> Cmd msg
port fsRemoveDirectoryRecursive : { id : String, path : String } -> Cmd msg
port fsCanonicalizePath : { id : String, path : String } -> Cmd msg
port fsGetCurrentDirectory : { id : String } -> Cmd msg
port fsGetAppUserDataDirectory : { id : String, appName : String } -> Cmd msg
port fsGetModificationTime : { id : String, path : String } -> Cmd msg
port fsLockFile : { id : String, path : String } -> Cmd msg
port fsUnlockFile : { id : String, path : String } -> Cmd msg

-- File System (incoming)
port fsResponse : ({ id : String, type_ : String, payload : Json.Value } -> msg) -> Sub msg

-- Console
port consoleWrite : { fd : Int, content : String } -> Cmd msg
port consoleGetLine : { id : String } -> Cmd msg
port consoleReplGetInputLine : { id : String, prompt : String } -> Cmd msg
port consoleReadStdin : { id : String } -> Cmd msg
port consoleResponse : ({ id : String, type_ : String, payload : Json.Value } -> msg) -> Sub msg

-- Process/Environment
port procLookupEnv : { id : String, name : String } -> Cmd msg
port procGetArgs : { id : String } -> Cmd msg
port procExit : { code : Int } -> Cmd msg
port procExitWithResponse : { response : Json.Value } -> Cmd msg
port procWithCreateProcess : { id : String, config : Json.Value } -> Cmd msg
port procWaitForProcess : { id : String, handle : Int } -> Cmd msg
port procResponse : ({ id : String, type_ : String, payload : Json.Value } -> msg) -> Sub msg

-- Concurrency
port concNewEmptyMVar : { id : String } -> Cmd msg
port concReadMVar : { id : String, mvarId : Int } -> Cmd msg
port concTakeMVar : { id : String, mvarId : Int } -> Cmd msg
port concPutMVar : { id : String, mvarId : Int, value : String } -> Cmd msg  -- base64 encoded
port concResponse : ({ id : String, type_ : String, payload : Json.Value } -> msg) -> Sub msg

-- Network
port netGetArchive : { id : String, url : String } -> Cmd msg
port netHttpUpload : { id : String, config : Json.Value } -> Cmd msg
port netResponse : ({ id : String, type_ : String, payload : Json.Value } -> msg) -> Sub msg
```

---

## Part 4: Migration Strategy

### 4.1 Phase 1: Foundation (Core Infrastructure)

**Files to create:**
1. `Utils/IO.elm` - IO monad type and combinators
2. `Utils/IO/Primitives.elm` - Primitive constructors
3. `System/IO/Ports.elm` - Port declarations
4. `System/IO/Interpreter.elm` - Step function and runtime

**Files to modify:**
1. `System/IO.elm` - Keep `Program` export, change implementation

**Testing:** Create simple test program that does file read/write.

### 4.2 Phase 2: Simple Operations

**Systematic replacement pattern:**

```elm
-- Before (Utils/Main.elm)
dirDoesFileExist : FilePath -> Task Never Bool
dirDoesFileExist filename =
    Impure.task "dirDoesFileExist" ...

-- After (Utils/Main.elm)
dirDoesFileExist : FilePath -> IO Never Bool
dirDoesFileExist =
    IO.doesFileExist
```

**Files to modify:**
1. `Utils/Main.elm` - All directory/file/environment operations
2. `Builder/File.elm` - File operations
3. `System/Exit.elm` - Exit operations
4. `System/Process.elm` - Process operations

### 4.3 Phase 3: Task Helper Migration

**Replace Task.Extra functions with IO equivalents:**

| Task.Extra | IO |
|------------|-----|
| `Task.pure` | `IO.pure` |
| `Task.bind` | `IO.andThen` |
| `Task.fmap` | `IO.map` |
| `Task.throw` | `IO.throw` |
| `Task.run` | `IO.run` |
| `Task.eio` | `IO.eio` |
| `Task.mio` | `IO.mio` |
| `Task.io` | `IO.io` |
| `Task.mapM` | `IO.traverse` |

**Approach:**
1. Create `Utils/IO/Extra.elm` with same API
2. Update imports across codebase
3. Eventually inline into `Utils/IO.elm`

### 4.4 Phase 4: Concurrency Migration

**Critical: MVar and forkIO patterns**

The fork/collect pattern needs careful handling:

```elm
-- Before
fork : (a -> BE.Encoder) -> Task Never a -> Task Never (MVar a)
fork encoder work =
    Utils.newEmptyMVar
        |> Task.bind (\mvar ->
            Utils.forkIO (Task.bind (Utils.putMVar encoder mvar) work)
                |> Task.fmap (\_ -> mvar))

-- After
fork : (a -> BE.Encoder) -> IO Never a -> IO Never (MVar a)
fork encoder work =
    IO.newEmptyMVar
        |> IO.andThen (\mvar ->
            IO.forkIO (IO.andThen (IO.putMVar encoder mvar) work)
                |> IO.map (\_ -> mvar))
```

**Key insight:** The `forkIO` primitive must be handled specially by the interpreter. It needs to:
1. Register a new "thread" in the model
2. Step that thread independently
3. Handle MVar blocking/waking across threads

### 4.5 Phase 5: Complex Files

**High-complexity files requiring careful attention:**

1. **Builder/Build.elm** (85+ binds)
   - Parallel compilation with fork/collect
   - Deep nesting of callbacks
   - Strategy: Migrate section by section, test each

2. **Builder/BackgroundWriter.elm**
   - Chan operations built on MVars
   - Concurrent write queue

3. **Terminal/Repl.elm**
   - StateT monad transformer
   - Interactive input loop

4. **Builder/Deps/Solver.elm**
   - Parallel package resolution
   - Network operations

### 4.6 Phase 6: Entry Points

**Files that define main:**
1. `Terminal/Main.elm` - CLI entry point
2. `API/Main.elm` - Library API entry point

These call `IO.run` to start the interpreter.

### 4.7 Phase 7: Cleanup

1. Remove `Utils/Impure.elm`
2. Remove `mock-xmlhttprequest` dependency
3. Remove `Utils/Task/Extra.elm`
4. Update `compiler/lib/index.js` to use elm-io-lib

---

## Part 5: File Change Summary

### New Files
| File | Purpose |
|------|---------|
| `Utils/IO.elm` | IO monad type and combinators |
| `Utils/IO/Primitives.elm` | Primitive operation constructors |
| `System/IO/Ports.elm` | Port declarations |
| `System/IO/Interpreter.elm` | Runtime and step functions |

### Modified Files (by complexity)

**Low Complexity (direct replacement):**
- `System/Exit.elm`
- `Builder/File.elm`
- `System/Process.elm`

**Medium Complexity:**
- `Utils/Main.elm` (many functions, but straightforward)
- `Terminal/Terminal.elm`
- `Builder/Elm/Outline.elm`
- `Builder/Stuff.elm`

**High Complexity:**
- `Builder/Build.elm`
- `Builder/BackgroundWriter.elm`
- `Builder/Elm/Details.elm`
- `Builder/Deps/Solver.elm`
- `Terminal/Repl.elm`
- `Builder/Generate.elm`
- `Builder/Reporting.elm`

**Entry Points:**
- `System/IO.elm` (major rewrite)
- `Terminal/Main.elm`
- `API/Main.elm`

### Deleted Files
- `Utils/Impure.elm`
- `Utils/Task/Extra.elm` (after migration complete)

---

## Part 6: Outstanding Questions

### Q1: MVar Value Encoding

**Current system:** MVars store binary-encoded Elm values using `BE.Encoder`/`BD.Decoder`.

**Question:** Should we:
a) Keep binary encoding (requires passing encoders/decoders everywhere)
b) Switch to JSON encoding (simpler but potentially slower)
c) Keep values in Elm-side Dict, only pass IDs to JS

**Recommendation:** Option (c) - Keep values in Elm Model, MVars are just IDs. This:
- Eliminates encoding overhead
- Keeps type safety
- Simplifies JS handler

### Q2: forkIO Implementation

**Current system:** Uses `Process.spawn` which is Elm runtime magic.

**Question:** How do we implement true concurrency with ports?

**Options:**
a) Single-threaded simulation (step each thread in round-robin)
b) Use Web Workers for true parallelism
c) Keep Process.spawn, wrap IO in Task internally

**Recommendation:** Option (a) for simplicity, with option to upgrade to (b) later. The key insight is that MVar blocking naturally creates interleaving points.

### Q3: StateT for REPL

**Current system:** Uses `getStateT`/`putStateT` Impure tasks with state stored in JS.

**Question:** Where should REPL state live?

**Options:**
a) Keep in JS, access via ports
b) Move to Elm Model in interpreter
c) Thread through IO as reader/state monad

**Recommendation:** Option (b) - Part of interpreter Model. The StateT pattern can be preserved in Elm using a State layer on top of IO.

### Q4: Fire-and-Forget Operations

**Current system:** `hPutStr` with `Always ()` resolver - no response expected.

**Question:** Should fire-and-forget operations:
a) Truly fire-and-forget (no Cmd continuation)
b) Wait for acknowledgment from JS
c) Use `requestAnimationFrame` / `setTimeout` to yield

**Recommendation:** Option (a) with batching. Send command, immediately continue stepping. This matches current semantics.

### Q5: Error in IO Never

**Question:** The compiler uses `IO Never a` (infallible) throughout. How do we handle JS-side errors?

**Current system:** Errors crash or are wrapped in Result.

**Recommendation:** Keep this pattern. JS handlers should never fail (or wrap errors in Result payload). The `Never` error type is preserved.

### Q6: Binary Data Encoding

**Current system:** Uses custom `Utils.Bytes.Encode`/`Decode` for binary data over HTTP.

**Question:** How to handle binary data over ports?

**Options:**
a) Base64 encode all binary data (~33% size overhead)
b) Patch Elm to support `Bytes` over ports (maps to `Uint8Array` in JS)
c) Keep binary data in JS, pass references

**Decision:** Option (b) - Patch Elm to support native Bytes over ports.

**Rationale:**
- Binary data is used extensively for MVar values and file operations
- Base64 encoding adds unacceptable overhead for large compiler data structures
- Future architecture may pass binary data between Elm processes in Web Workers
- Native `Bytes` ↔ `Uint8Array` mapping is the cleanest solution

**See:** [Prerequisite: Bytes Over Ports](#prerequisite-bytes-over-ports) section below.

---

## Part 7: Risk Assessment

### High Risk
1. **MVar semantics** - Must exactly match blocking behavior
2. **forkIO timing** - Concurrent execution order matters
3. **Deep chains in Builder/Build.elm** - Complex control flow

### Medium Risk
1. **Binary encoding changes** - May affect artifact compatibility
2. **StateT migration** - REPL state handling
3. **Process spawning** - withCreateProcess complexity

### Low Risk
1. **Simple file operations** - Direct mapping
2. **Console output** - Fire-and-forget
3. **Environment variables** - Simple lookup

---

## Part 8: Testing Strategy

### Unit Tests
1. Each IO primitive in isolation
2. Monad laws (associativity, identity)
3. Error handling (throw/catch)

### Integration Tests
1. Simple compile (single file)
2. Multi-file project compile
3. Package install/uninstall
4. REPL session

### Regression Tests
1. All existing test suite must pass
2. Performance benchmarks (compile time)
3. Memory usage monitoring

### Manual Testing
1. Interactive REPL
2. Large project compilation
3. Parallel compilation verification

---

## Prerequisite: Bytes Over Ports

**STATUS: BLOCKING** - This prerequisite must be completed before the IO monad migration can proceed.

### The Problem

Standard Elm ports cannot send `Bytes.Bytes` directly. Supported types are:
- `Json.Value`, `String`, `Int`, `Float`, `Bool`
- `List`, `Array`, `Maybe`
- Records with supported types

**Not supported:** `Bytes.Bytes`, `ArrayBuffer`, `Uint8Array`

### Binary Data Usage in Current System

Analysis of the codebase reveals extensive binary data transfer:

#### MVar Operations (Most Critical)

All MVar read/write operations use binary encoding:

```elm
-- MVar put sends Bytes
putMVar : (a -> BE.Encoder) -> MVar a -> a -> Task Never ()
putMVar encoder (MVar ref) value =
    Impure.task "putMVar" [Http.header "id" (String.fromInt ref)]
        (Impure.BytesBody (encoder value)) (Impure.Always ())

-- MVar read/take returns Bytes
readMVar : BD.Decoder a -> MVar a -> Task Never a
readMVar decoder (MVar ref) =
    Impure.task "readMVar" [] (Impure.StringBody (String.fromInt ref))
        (Impure.BytesResolver decoder)
```

**Data stored in MVars includes:**
| MVar Type | Contents |
|-----------|----------|
| `MVar Status` | Module compilation status (cached/changed/error) |
| `MVar BResult` | Build results per module |
| `MVar StatusDict` | Dict of module name → MVar Status |
| `MVar CachedInterface` | Interface definitions |
| `MVar Dep` | Dependencies (module name + interface) |
| `MVar (Maybe Opt.LocalGraph)` | Optimization graphs |
| `MVar Http.Manager` | HTTP connection manager |

#### File Operations

```elm
-- Read binary files
binaryDecodeFileOrFail : BD.Decoder a -> FilePath -> Task Never (Result (Int, String) a)
    -- Uses BytesResolver

-- Write binary files
binaryEncodeFile : (a -> BE.Encoder) -> FilePath -> a -> Task Never ()
    -- Uses BytesBody
```

### Required Elm Patch

Modify Elm's kernel code to:
1. Allow `Bytes.Bytes` as a port type
2. Map `Bytes.Bytes` ↔ `Uint8Array` at the JS boundary
3. Handle both incoming and outgoing ports

### Future Architecture Consideration

The Bytes-over-ports capability enables:
- Passing binary data to Web Worker threads running separate Elm processes
- Efficient inter-process communication for parallel compilation
- Zero-copy data transfer where possible

### Next Steps

1. **Investigate Elm's port implementation** in kernel code
2. **Design the patch** for Bytes support
3. **Implement and test** the patch
4. **Resume IO monad migration** once ports support Bytes

---

## Appendix A: Migration Checklist

### Prerequisite (BLOCKING)
- [ ] **Patch Elm to support Bytes over ports** (see Prerequisite section above)
  - [ ] Investigate Elm kernel port implementation
  - [ ] Design Bytes ↔ Uint8Array mapping
  - [ ] Implement outgoing port support for Bytes
  - [ ] Implement incoming port (Sub) support for Bytes
  - [ ] Test with simple Bytes port program

### Phase 1: Foundation
- [ ] Create Utils/IO.elm with monad implementation
- [ ] Create Utils/IO/Primitives.elm
- [ ] Create System/IO/Ports.elm with all port declarations
- [ ] Create System/IO/Interpreter.elm
- [ ] Rewrite System/IO.elm to use interpreter
- [ ] Create elm-io-lib/js handlers (or adapt existing)
- [ ] Migrate Utils/Main.elm file operations
- [ ] Migrate Utils/Main.elm MVar operations
- [ ] Migrate System/Exit.elm
- [ ] Migrate System/Process.elm
- [ ] Migrate Builder/File.elm
- [ ] Replace Task.bind with IO.andThen across codebase
- [ ] Replace Task.fmap with IO.map across codebase
- [ ] Replace Task.pure with IO.pure across codebase
- [ ] Replace Task.throw with IO.throw across codebase
- [ ] Replace Task.eio with IO.eio across codebase
- [ ] Replace Task.mio with IO.mio across codebase
- [ ] Migrate Builder/Build.elm (careful, complex)
- [ ] Migrate Builder/Elm/Details.elm
- [ ] Migrate Builder/BackgroundWriter.elm
- [ ] Migrate Terminal/Repl.elm
- [ ] Migrate Builder/Deps/Solver.elm
- [ ] Update Terminal/Main.elm entry point
- [ ] Update API/Main.elm entry point
- [ ] Update compiler/lib/index.js
- [ ] Remove Utils/Impure.elm
- [ ] Remove Utils/Task/Extra.elm
- [ ] Full test suite passes
- [ ] Performance verification
