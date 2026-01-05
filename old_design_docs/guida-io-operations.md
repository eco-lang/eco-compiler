# Guida I/O Operations Analysis

Comprehensive analysis of I/O operations in the Guida compiler, based on analysis of `guida/lib/index.js` and corresponding Elm bindings.

## Architecture Overview

Guida implements I/O operations using a mock XMLHttpRequest server pattern:

- **JavaScript Runtime**: `guida/lib/index.js` creates a mock HTTP server using `mock-xmlhttprequest`
- **Elm Bindings**: Operations exposed via `Utils.Impure` module which wraps HTTP requests as Elm Tasks
- **Communication**: Elm code makes POST requests to operation endpoints; JS handlers execute native operations
- **Error Handling**: Operations are wrapped as `Task Never a` - errors cause crashes rather than returning Result types
- **Execution Model**: Asynchronous via Elm's Task system; JS handlers use async/await for Node.js operations

## File System Operations

### 1. read (readUtf8)

**Endpoint**: `POST /read`

**Parameters**:
- `path` (String) - File path to read, sent as request body

**Return Type**: `Task Never String`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:84-87`):
```javascript
server.post("read", async (request) => {
    const content = await config.readFile(request.body);
    request.respond(200, null, content);
});
```

**Elm Binding** (`guida/src/Builder/File.elm`):
```elm
readUtf8 : FilePath -> Task Never String
readUtf8 path =
    Impure.task "read" [] (Impure.StringBody path) (Impure.StringResolver identity)
```

**Usage Locations**: 17 usages across Elm codebase

**Notes**: Delegates to config.readFile which is provided by the runtime environment (Node.js fs.readFile or browser FileSystem API)

---

### 2. writeString

**Endpoint**: `POST /writeString`

**Parameters**:
- `path` (String) - File path, sent as HTTP header
- `content` (String) - File content, sent as request body

**Return Type**: `Task Never ()`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:77-82`):
```javascript
server.post("writeString", async (request) => {
    const path = request.requestHeaders.getHeader("path");
    await config.writeFile(path, request.body);
    request.respond(200);
});
```

**Elm Binding** (`guida/src/System/IO.elm:114-119`):
```elm
writeString : FilePath -> String -> Task Never ()
writeString path content =
    Impure.task "writeString"
        [ Http.header "path" path ]
        (Impure.StringBody content)
        (Impure.Always ())
```

**Usage Locations**: 8 usages across Elm codebase

**Notes**: Specifically for writing string content; separate from `write` operation which handles binary data

---

### 3. write (binaryEncodeFile)

**Endpoint**: `POST /write`

**Parameters**:
- `path` (String) - File path, sent as HTTP header
- `data` (Bytes) - Binary data, sent as request body

**Return Type**: `Task Never ()`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:186-191`):
```javascript
server.post("write", async (request) => {
    const path = request.requestHeaders.getHeader("path");
    await config.writeFile(path, request.body);
    request.respond(200);
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:1160-1166`):
```elm
binaryEncodeFile : (a -> BE.Encoder) -> FilePath -> a -> Task Never ()
binaryEncodeFile toEncoder path value =
    Impure.task "write"
        [ Http.header "path" path ]
        (Impure.BytesBody (toEncoder value))
        (Impure.Always ())
```

**Usage Locations**: 4 usages across Elm codebase

**Notes**: Used for writing binary-encoded data (e.g., compiled artifacts, cache files)

---

### 4. binaryDecodeFileOrFail

**Endpoint**: `POST /binaryDecodeFileOrFail`

**Parameters**:
- `path` (String) - File path, sent as request body

**Return Type**: `Task Never (Result (Int, String) a)`

**Return Behavior**: Always returns; decoding errors wrapped in Result.Err

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:181-184`):
```javascript
server.post("binaryDecodeFileOrFail", async (request) => {
    const data = await config.readFile(request.body);
    request.respond(200, null, data.buffer);
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:1152-1158`):
```elm
binaryDecodeFileOrFail : BD.Decoder a -> FilePath -> Task Never (Result ( Int, String ) a)
binaryDecodeFileOrFail decoder filename =
    Impure.task "binaryDecodeFileOrFail"
        []
        (Impure.StringBody filename)
        (Impure.BytesResolver (BD.map Ok decoder))
```

**Usage Locations**: 5 usages across Elm codebase

**Notes**: Unlike other I/O operations, this returns a Result to handle decoding failures gracefully

---

### 5. dirDoesFileExist

**Endpoint**: `POST /dirDoesFileExist`

**Parameters**:
- `path` (String) - File path to check, sent as request body

**Return Type**: `Task Never Bool`

**Return Behavior**: Always returns; false if file doesn't exist or is a directory

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:97-104`):
```javascript
server.post("dirDoesFileExist", async (request) => {
    try {
        const stats = await config.details(request.body);
        request.respond(200, null, stats.type === "file");
    } catch (_err) {
        request.respond(200, null, false);
    }
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:775-780`):
```elm
dirDoesFileExist : FilePath -> Task Never Bool
dirDoesFileExist filename =
    Impure.task "dirDoesFileExist"
        []
        (Impure.StringBody filename)
        (Impure.DecoderResolver Decode.bool)
```

**Usage Locations**: 14 usages across Elm codebase

**Notes**: Distinguishes files from directories; returns false for directories

---

### 6. dirDoesDirectoryExist

**Endpoint**: `POST /dirDoesDirectoryExist`

**Parameters**:
- `path` (String) - Directory path to check, sent as request body

**Return Type**: `Task Never Bool`

**Return Behavior**: Always returns; false if directory doesn't exist or is a file

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:163-170`):
```javascript
server.post("dirDoesDirectoryExist", async (request) => {
    try {
        const stats = await config.details(request.body);
        request.respond(200, null, stats.type === "directory");
    } catch (_err) {
        request.respond(200, null, false);
    }
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:845-850`):
```elm
dirDoesDirectoryExist : FilePath -> Task Never Bool
dirDoesDirectoryExist path =
    Impure.task "dirDoesDirectoryExist"
        []
        (Impure.StringBody path)
        (Impure.DecoderResolver Decode.bool)
```

**Usage Locations**: 14 usages across Elm codebase

**Notes**: Distinguishes directories from files; returns false for files

---

### 7. dirCreateDirectoryIfMissing

**Endpoint**: `POST /dirCreateDirectoryIfMissing`

**Parameters**:
- `createParents` (Bool) - Whether to create parent directories
- `filename` (String) - Directory path to create

Parameters sent as JSON object in request body.

**Return Type**: `Task Never ()`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:106-127`):
```javascript
server.post("dirCreateDirectoryIfMissing", async (request) => {
    const { createParents, filename } = JSON.parse(request.body);
    let directories = [filename];
    let prefix = filename.startsWith("/") ? "/" : "";

    if (createParents) {
        directories = filename.split('/').filter(Boolean);
        directories = directories.map((_, index) => prefix + directories.slice(0, index + 1).join('/'));
    }

    await directories.reduce(async (previousPromise, directory) => {
        await previousPromise;
        try {
            await config.details(directory);
        } catch (_err) {
            await config.createDirectory(directory);
        }
    }, Promise.resolve());

    request.respond(200);
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:791-802`):
```elm
dirCreateDirectoryIfMissing : Bool -> FilePath -> Task Never ()
dirCreateDirectoryIfMissing createParents filename =
    Impure.task "dirCreateDirectoryIfMissing"
        []
        (Impure.JsonBody
            (Encode.object
                [ ( "createParents", Encode.bool createParents )
                , ( "filename", Encode.string filename )
                ]
            )
        )
        (Impure.Always ())
```

**Usage Locations**: 18 usages across Elm codebase

**Notes**: Similar to `mkdir -p` when createParents is true; idempotent (doesn't fail if directory exists)

---

### 8. dirListDirectory

**Endpoint**: `POST /dirListDirectory`

**Parameters**:
- `path` (String) - Directory path, sent as request body

**Return Type**: `Task Never (List String)`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:176-179`):
```javascript
server.post("dirListDirectory", async (request) => {
    const { files } = await config.readDirectory(request.body);
    request.respond(200, null, JSON.stringify(files));
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:881-886`):
```elm
dirListDirectory : FilePath -> Task Never (List FilePath)
dirListDirectory path =
    Impure.task "dirListDirectory"
        []
        (Impure.StringBody path)
        (Impure.DecoderResolver (Decode.list Decode.string))
```

**Usage Locations**: 7 usages across Elm codebase

**Notes**: Returns only filenames, not full paths

---

### 9. dirGetModificationTime

**Endpoint**: `POST /dirGetModificationTime`

**Parameters**:
- `path` (String) - File/directory path, sent as request body

**Return Type**: `Task Never Time.Posix`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:158-161`):
```javascript
server.post("dirGetModificationTime", async (request) => {
    const stats = await config.details(request.body);
    request.respond(200, null, stats.createdAt);
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:821-826`):
```elm
dirGetModificationTime : FilePath -> Task Never Time.Posix
dirGetModificationTime filename =
    Impure.task "dirGetModificationTime"
        []
        (Impure.StringBody filename)
        (Impure.DecoderResolver (Decode.map Time.millisToPosix Decode.int))
```

**Usage Locations**: 5 usages across Elm codebase

**Notes**: Currently returns `createdAt` instead of modification time (likely a bug); used for cache invalidation

---

### 10. dirGetCurrentDirectory

**Endpoint**: `POST /dirGetCurrentDirectory`

**Parameters**: None

**Return Type**: `Task Never String`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:193-196`):
```javascript
server.post("dirGetCurrentDirectory", async (request) => {
    const currentDir = await config.getCurrentDirectory();
    request.respond(200, null, currentDir);
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:805-810`):
```elm
dirGetCurrentDirectory : Task Never String
dirGetCurrentDirectory =
    Impure.task "dirGetCurrentDirectory"
        []
        Impure.EmptyBody
        (Impure.StringResolver identity)
```

**Usage Locations**: 6 usages across Elm codebase

**Notes**: Returns absolute path of current working directory

---

### 11. dirCanonicalizePath

**Endpoint**: `POST /dirCanonicalizePath`

**Parameters**:
- `path` (String) - Path to canonicalize, sent as request body

**Return Type**: `Task Never String`

**Return Behavior**: Always returns; currently just echoes input

**Sync/Async**: Synchronous (but wrapped as async task)

**Implementation** (`guida/lib/index.js:172-174`):
```javascript
server.post("dirCanonicalizePath", (request) => {
    request.respond(200, null, request.body);
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:853-858`):
```elm
dirCanonicalizePath : FilePath -> Task Never FilePath
dirCanonicalizePath path =
    Impure.task "dirCanonicalizePath"
        []
        (Impure.StringBody path)
        (Impure.StringResolver identity)
```

**Usage Locations**: 7 usages across Elm codebase

**Notes**: Currently a no-op (returns input unchanged); should resolve symlinks and relative paths

---

### 12. dirGetAppUserDataDirectory

**Endpoint**: `POST /dirGetAppUserDataDirectory`

**Parameters**:
- `appName` (String) - Application name, sent as request body

**Return Type**: `Task Never String`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:203-206`):
```javascript
server.post("dirGetAppUserDataDirectory", async (request) => {
    const homedir = await config.homedir();
    request.respond(200, null, `${homedir}/.${request.body}`);
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:813-818`):
```elm
dirGetAppUserDataDirectory : FilePath -> Task Never FilePath
dirGetAppUserDataDirectory filename =
    Impure.task "dirGetAppUserDataDirectory"
        []
        (Impure.StringBody filename)
        (Impure.StringResolver identity)
```

**Usage Locations**: 5 usages across Elm codebase

**Notes**: Returns `~/.{appName}` path; used for storing user-specific data/cache

---

### 13. lockFile / unlockFile

**Endpoint**: `POST /lockFile`, `POST /unlockFile`

**Parameters** (lockFile):
- `path` (String) - File path to lock, sent as request body

**Parameters** (unlockFile):
- `path` (String) - File path to unlock, sent as request body

**Return Type**: `Task Never ()`

**Return Behavior**: Always returns; lockFile blocks if file already locked

**Sync/Async**: Asynchronous (lockFile may block)

**Implementation** (`guida/lib/index.js:129-156`):
```javascript
server.post("lockFile", (request) => {
    const path = request.body;
    if (lockedFiles[path]) {
        lockedFiles[path].subscribers.push(request);
    } else {
        lockedFiles[path] = { subscribers: [] };
        request.respond(200);
    }
});

server.post("unlockFile", (request) => {
    const path = request.body;
    if (lockedFiles[path]) {
        const subscriber = lockedFiles[path].subscribers.shift();
        if (subscriber) {
            subscriber.respond(200);
        } else {
            delete lockedFiles[path];
        }
        request.respond(200);
    } else {
        console.error(`Could not find locked file "${path}"!`);
    }
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:755-768`):
```elm
lockFile : FilePath -> Task Never ()
lockFile path =
    Impure.task "lockFile"
        []
        (Impure.StringBody path)
        (Impure.Always ())

unlockFile : FilePath -> Task Never ()
unlockFile path =
    Impure.task "unlockFile"
        []
        (Impure.StringBody path)
        (Impure.Always ())
```

**Usage Locations**: lockFile: 4, unlockFile: 4

**Notes**: Implements advisory file locking using queued requests; not OS-level file locks

---

## I/O Operations

### 14. hPutStr

**Endpoint**: `POST /hPutStr`

**Parameters**:
- `fd` (Int) - File descriptor (1=stdout, 2=stderr), sent as HTTP header
- `content` (String) - Content to write, sent as request body

**Return Type**: `Task Never ()`

**Return Behavior**: Always returns on success; crashes for invalid fd

**Sync/Async**: Synchronous (but wrapped as async task)

**Implementation** (`guida/lib/index.js:63-75`):
```javascript
server.post("hPutStr", (request) => {
    const fd = parseInt(request.requestHeaders.getHeader("fd"));

    if (fd === 1) {
        console.log(request.body);
    } else if (fd === 2) {
        console.error(request.body);
    } else {
        throw new Error(`Invalid file descriptor: ${fd}`);
    }

    request.respond(200);
});
```

**Elm Binding** (`guida/src/System/IO.elm:234-239`):
```elm
hPutStr : Handle -> String -> Task Never ()
hPutStr (Handle fd) content =
    Impure.task "hPutStr"
        [ Http.header "fd" (String.fromInt fd) ]
        (Impure.StringBody content)
        (Impure.Always ())
```

**Usage Locations**: 11 usages across Elm codebase

**Notes**: Only supports stdout(1) and stderr(2); used for all console output

---

### 15. hPutStrLn

**Elm-only helper** - Not a separate JS operation

**Elm Implementation** (`guida/src/System/IO.elm:242-244`):
```elm
hPutStrLn : Handle -> String -> Task Never ()
hPutStrLn handle content =
    hPutStr handle (content ++ "\n")
```

**Usage Locations**: 13 usages across Elm codebase

**Notes**: Convenience wrapper that adds newline

---

### 16. putStr / putStrLn

**Elm-only helpers** - Not separate JS operations

**Elm Implementation** (`guida/src/System/IO.elm:251-258`):
```elm
putStr : String -> Task Never ()
putStr =
    hPutStr stdout

putStrLn : String -> Task Never ()
putStrLn s =
    putStr (s ++ "\n")
```

**Usage Locations**: putStr: 9, putStrLn: 42

**Notes**: Convenience wrappers for stdout output

---

## Environment Operations

### 17. envLookupEnv

**Endpoint**: `POST /envLookupEnv`

**Parameters**:
- `name` (String) - Environment variable name, sent as request body

**Return Type**: `Task Never (Maybe String)`

**Return Behavior**: Always returns; Nothing if variable not set

**Sync/Async**: Synchronous (but wrapped as async task)

**Implementation** (`guida/lib/index.js:198-201`):
```javascript
server.post("envLookupEnv", (request) => {
    const envVar = config.env[request.body] ?? null;
    request.respond(200, null, JSON.stringify(envVar));
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:893-898`):
```elm
envLookupEnv : String -> Task Never (Maybe String)
envLookupEnv name =
    Impure.task "envLookupEnv"
        []
        (Impure.StringBody name)
        (Impure.DecoderResolver (Decode.maybe Decode.string))
```

**Usage Locations**: 6 usages across Elm codebase

**Notes**: Reads from config.env object provided at runtime

---

### 18. getArgs (envGetArgs)

**Endpoint**: `POST /getArgs`

**Parameters**: None

**Return Type**: `Task Never (List String)`

**Return Behavior**: Always returns

**Sync/Async**: Synchronous (but wrapped as async task)

**Implementation** (`guida/lib/index.js:279-281`):
```javascript
server.post("getArgs", (request) => {
    request.respond(200, null, JSON.stringify(args));
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:906-911`):
```elm
envGetArgs : Task Never (List String)
envGetArgs =
    Impure.task "envGetArgs"
        []
        Impure.EmptyBody
        (Impure.DecoderResolver (Decode.list Decode.string))
```

**Usage Locations**: 5 usages across Elm codebase

**Notes**: Returns command-line arguments passed to Guida

---

### 19. exitWithResponse

**Endpoint**: `POST /exitWithResponse`

**Parameters**:
- `response` (JSON) - Exit response data, sent as request body

**Return Type**: Never returns (exits program)

**Return Behavior**: Resolves the runGuida promise with the response data

**Sync/Async**: Synchronous (terminates execution)

**Implementation** (`guida/lib/index.js:283-285`):
```javascript
server.post("exitWithResponse", (request) => {
    resolve(JSON.parse(request.body));
});
```

**Elm Binding**: Not directly exposed; used internally by System.Exit

**Usage Locations**: Used by exit mechanism, not directly called

**Notes**: Primary mechanism for returning results from Guida to the caller

---

## Network Operations

### 20. getArchive

**Endpoint**: `POST /getArchive`

**Parameters**:
- `url` (String) - URL of ZIP archive to download, sent as request body

**Return Type**: `Task Never { sha : String, archive : List ZipEntry }`

**Return Behavior**: Always returns on success; crashes on failure

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:89-95`):
```javascript
server.post("getArchive", (request) => {
    download.apply({
        send: ({ sha, archive }) => {
            request.respond(200, null, JSON.stringify({ sha, archive }));
        }
    }, ["GET", request.body]);
});
```

The `download` function (`guida/lib/index.js:10-59`) handles:
- HTTP GET request
- SHA-1 hash computation of response
- ZIP file decompression using JSZip
- Following redirects (Location header)
- Error handling for network/timeout issues

**Elm Binding**: Not directly exposed in Utils.Main; likely used internally

**Usage Locations**: 6 usages (searched for "getArchive")

**Notes**: Used for downloading Elm packages; includes integrity checking via SHA-1

---

### 21. Default HTTP Handler

**Pattern**: All non-matching URLs

**Parameters**: Arbitrary (forwarded from Elm Http.request)

**Return Type**: Depends on request

**Return Behavior**: Forwards to actual HTTP endpoint

**Sync/Async**: Asynchronous

**Implementation** (`guida/lib/index.js:292-307`):
```javascript
server.setDefaultHandler((request) => {
    const headers = request.requestHeaders.getHash();

    var xhr = new config.XMLHttpRequest();
    xhr.open(request.method, request.url, true);

    for (const key in headers) {
        if (Object.prototype.hasOwnProperty.call(headers, key) && key !== "user-agent") {
            xhr.setRequestHeader(key, headers[key]);
        }
    }
    xhr.onload = function () {
        request.respond(200, null, this.responseText);
    };
    xhr.send(request.body);
});
```

**Elm Binding**: Any Http.task not matching above patterns

**Usage Locations**: Used for package registry HTTP requests

**Notes**: Allows Guida to make real HTTP requests for package downloads, etc.

---

## Concurrency Operations

### 22. newEmptyMVar

**Endpoint**: `POST /newEmptyMVar`

**Parameters**: None

**Return Type**: `Task Never (MVar a)`

**Return Behavior**: Always returns

**Sync/Async**: Synchronous (but wrapped as async task)

**Implementation** (`guida/lib/index.js:209-213`):
```javascript
server.post("newEmptyMVar", (request) => {
    mVarsNextCounter += 1;
    mVars[mVarsNextCounter] = { subscribers: [], value: undefined };
    request.respond(200, null, mVarsNextCounter);
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:1071-1076`):
```elm
newEmptyMVar : Task Never (MVar a)
newEmptyMVar =
    Impure.task "newEmptyMVar"
        []
        Impure.EmptyBody
        (Impure.DecoderResolver (Decode.map MVar Decode.int))
```

**Usage Locations**: 21 usages across Elm codebase

**Notes**: MVars are Haskell-style synchronization primitives; implemented as in-memory structures with queued subscribers

---

### 23. readMVar

**Endpoint**: `POST /readMVar`

**Parameters**:
- `id` (Int) - MVar ID, sent as request body

**Return Type**: `Task Never a` (decoded from bytes)

**Return Behavior**: Blocks if MVar is empty until value available

**Sync/Async**: Asynchronous (may block)

**Implementation** (`guida/lib/index.js:215-223`):
```javascript
server.post("readMVar", (request) => {
    const id = request.body;

    if (typeof mVars[id].value === "undefined") {
        mVars[id].subscribers.push({ action: "read", request });
    } else {
        request.respond(200, null, mVars[id].value.buffer);
    }
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:1036-1041`):
```elm
readMVar : BD.Decoder a -> MVar a -> Task Never a
readMVar decoder (MVar ref) =
    Impure.task "readMVar"
        []
        (Impure.StringBody (String.fromInt ref))
        (Impure.BytesResolver decoder)
```

**Usage Locations**: 43 usages across Elm codebase

**Notes**: Non-destructive read (value remains in MVar); multiple readers can be queued

---

### 24. takeMVar

**Endpoint**: `POST /takeMVar`

**Parameters**:
- `id` (Int) - MVar ID, sent as request body

**Return Type**: `Task Never a` (decoded from bytes)

**Return Behavior**: Blocks if MVar is empty until value available; removes value

**Sync/Async**: Asynchronous (may block)

**Implementation** (`guida/lib/index.js:225-245`):
```javascript
server.post("takeMVar", (request) => {
    const id = request.body;

    if (typeof mVars[id].value === "undefined") {
        mVars[id].subscribers.push({ action: "take", request });
    } else {
        const value = mVars[id].value;
        mVars[id].value = undefined;

        if (
            mVars[id].subscribers.length > 0 &&
            mVars[id].subscribers[0].action === "put"
        ) {
            const subscriber = mVars[id].subscribers.shift();
            mVars[id].value = subscriber.value;
            request.respond(200);
        }

        request.respond(200, null, value.buffer);
    }
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:1055-1060`):
```elm
takeMVar : BD.Decoder a -> MVar a -> Task Never a
takeMVar decoder (MVar ref) =
    Impure.task "takeMVar"
        []
        (Impure.StringBody (String.fromInt ref))
        (Impure.BytesResolver decoder)
```

**Usage Locations**: 16 usages across Elm codebase

**Notes**: Destructive read; empties the MVar; may immediately refill from queued put

---

### 25. putMVar

**Endpoint**: `POST /putMVar`

**Parameters**:
- `id` (Int) - MVar ID, sent as HTTP header
- `value` (Bytes) - Value to put, sent as request body

**Return Type**: `Task Never ()`

**Return Behavior**: Blocks if MVar is full until space available

**Sync/Async**: Asynchronous (may block)

**Implementation** (`guida/lib/index.js:247-276`):
```javascript
server.post("putMVar", (request) => {
    const id = request.requestHeaders.getHeader("id");
    const value = request.body;

    if (typeof mVars[id].value === "undefined") {
        mVars[id].value = value;

        mVars[id].subscribers = mVars[id].subscribers.filter((subscriber) => {
            if (subscriber.action === "read") {
                subscriber.request.respond(200, null, value.buffer);
            }
            return subscriber.action !== "read";
        });

        const subscriber = mVars[id].subscribers.shift();

        if (subscriber) {
            subscriber.request.respond(200, null, value.buffer);

            if (subscriber.action === "take") {
                mVars[id].value = undefined;
            }
        }

        request.respond(200);
    } else {
        mVars[id].subscribers.push({ action: "put", request, value });
    }
});
```

**Elm Binding** (`guida/src/Utils/Main.elm:1063-1068`):
```elm
putMVar : (a -> BE.Encoder) -> MVar a -> a -> Task Never ()
putMVar encoder (MVar ref) value =
    Impure.task "putMVar"
        [ Http.header "id" (String.fromInt ref) ]
        (Impure.BytesBody (encoder value))
        (Impure.Always ())
```

**Usage Locations**: 32 usages across Elm codebase

**Notes**: Blocks on full MVar; immediately wakes queued readers/takers

---

### 26. forkIO

**Elm-only operation** - Uses Elm's Process.spawn

**Elm Implementation** (`guida/src/Utils/Main.elm:1013-1015`):
```elm
forkIO : Task Never () -> Task Never ThreadId
forkIO =
    Process.spawn
```

**Usage Locations**: 11 usages across Elm codebase

**Notes**: Spawns concurrent Elm process; no JS implementation needed

---

### 27. Chan operations (newChan, readChan, writeChan)

**Implementation**: Built on top of MVars in Elm; no direct JS operations

**Elm Implementation** (`guida/src/Utils/Main.elm:1083-1136`):
- Channels implemented as pairs of MVars
- One MVar for read end, one for write end
- Uses linked list of MVars for queue

**Usage Locations**: newChan: 5, readChan: 5, writeChan: 7

**Notes**: Haskell-style unbounded channels; implemented entirely in Elm using MVars

---

## Operations NOT Implemented

The following operations are referenced in Elm code but have no JS implementation:

### dirRemoveFile
- **Elm binding exists**: Yes (`guida/src/Utils/Main.elm:829-834`)
- **JS implementation**: NO - would crash with "handler not implemented"
- **Usage**: 5 usages

### dirRemoveDirectoryRecursive
- **Elm binding exists**: Yes (`guida/src/Utils/Main.elm:837-842`)
- **JS implementation**: NO - would crash with "handler not implemented"
- **Usage**: 5 usages

### dirFindExecutable
- **Elm binding exists**: Yes (`guida/src/Utils/Main.elm:783-788`)
- **JS implementation**: NO - would crash with "handler not implemented"
- **Usage**: 10 usages

### dirWithCurrentDirectory
- **Elm binding exists**: Yes (`guida/src/Utils/Main.elm:861-878`)
- **JS implementation**: NO - would crash with "handler not implemented"
- **Usage**: 7 usages

### withFile / hClose / hFileSize
- **Elm bindings exist**: Yes (`guida/src/System/IO.elm`)
- **JS implementation**: NO
- **Usage**: Not directly called

### replGetInputLine
- **Elm binding exists**: Yes (`guida/src/Utils/Main.elm:1208-1213`)
- **JS implementation**: NO - would crash with "handler not implemented"
- **Usage**: 6 usages

### getLine / readStdin
- **Elm binding exists**: Yes
- **JS implementation**: NO - would crash with "handler not implemented"
- **Usage**: getLine: 7 usages

**Note**: The catch-all handler at line 288 would throw an error for these:
```javascript
server.post(/^\w+$/, (request) => {
    throw new Error(`${request.url} handler not implemented!`);
});
```

---

## Summary Statistics

### Implemented Operations
- **File System**: 13 operations (read, write, writeString, binaryDecodeFileOrFail, existence checks, directory operations, locking)
- **I/O**: 4 operations (hPutStr, and derived helpers)
- **Environment**: 2 operations (envLookupEnv, getArgs)
- **Network**: 2 operations (getArchive, default HTTP handler)
- **Concurrency**: 4 MVar operations (newEmptyMVar, readMVar, takeMVar, putMVar)
- **Control**: 1 operation (exitWithResponse)

**Total: 26 distinct JS operations**

### Unimplemented Operations
- dirRemoveFile
- dirRemoveDirectoryRecursive
- dirFindExecutable
- dirWithCurrentDirectory
- withFile/hClose/hFileSize
- replGetInputLine
- getLine/readStdin

**Total: 7+ operations defined in Elm but not implemented in JS**

---

## Design Observations

### Strengths
1. **Clean abstraction**: Mock HTTP server provides clean boundary between Elm and JS
2. **Type safety**: Elm's Task types ensure proper sequencing of I/O operations
3. **Composability**: MVars enable building higher-level concurrency primitives (Chans)
4. **No error handling burden**: `Task Never a` means errors cause crashes (appropriate for compiler)

### Weaknesses
1. **Incomplete implementation**: Many operations have Elm bindings but no JS handlers
2. **Error handling**: All errors crash; no graceful degradation
3. **No streaming**: All file operations are all-or-nothing (entire contents)
4. **Limited I/O**: No stdin reading, no interactive input
5. **Canonicalization no-op**: dirCanonicalizePath doesn't actually canonicalize
6. **Modification time bug**: Returns creation time instead of modification time
7. **Advisory locks only**: File locking not enforced by OS

### Missing for General CLI Use
1. **Stdin operations**: No way to read from stdin (readStdin not implemented)
2. **Interactive prompts**: replGetInputLine not implemented
3. **Streaming I/O**: No support for reading/writing file chunks
4. **File deletion**: dirRemoveFile not implemented
5. **Process execution**: No way to spawn child processes (exec, spawn)
6. **Signal handling**: No signal handlers (SIGINT, SIGTERM, etc.)
7. **TTY detection**: hIsTerminalDevice always returns true
8. **Symlinks**: No symlink operations
9. **File permissions**: No way to read/modify permissions
10. **File watching**: No file system watching capabilities

---

## Recommendations for ECO Runtime

Based on this analysis, the ECO kernel package should:

### Core I/O Package Structure
```
Kernel.IO
├── File (read, write, exists, delete, move, copy, permissions)
├── Directory (list, create, delete, current, change)
├── Path (combine, canonicalize, relative, absolute)
├── Console (stdout, stderr, stdin, readLine, isTerminal)
├── Env (get, set, args, cwd)
├── Process (spawn, exec, exit, signal)
└── Concurrent (MVar, Chan, fork, async/await primitives)
```

### Key Design Decisions

1. **Error Handling**: Use `Task Error a` instead of `Task Never a`
   - Allow graceful error recovery
   - Include structured error types (FileNotFound, PermissionDenied, etc.)

2. **Streaming Support**: Add chunked I/O operations
   - `readChunk : Int -> Handle -> Task Error Bytes`
   - `writeChunk : Bytes -> Handle -> Task Error ()`
   - Enable processing large files without loading entirely into memory

3. **Complete Implementation**: Ensure all exposed operations are actually implemented
   - Remove unimplemented operations from API
   - Or implement them properly with clear error messages

4. **Stdin Support**: Full stdin reading capabilities
   - `readLine : Task Error String`
   - `readAll : Task Error String`
   - `readBytes : Int -> Task Error Bytes`

5. **Process Management**: Child process support
   - `spawn : String -> List String -> Task Error Process`
   - `exec : String -> Task Error { stdout : String, stderr : String, exitCode : Int }`
   - `pipe : List Process -> Task Error Process`

6. **Path Operations**: Proper path handling
   - Actual canonicalization (resolve symlinks, normalize)
   - Cross-platform path separators
   - Path validation

7. **File Metadata**: Rich file information
   - True modification/access/creation times
   - File permissions/mode
   - File type detection (file/dir/symlink/etc.)

8. **Resource Management**: Explicit resource cleanup
   - `bracket : Task e a -> (a -> Task e b) -> (a -> Task e c) -> Task e c`
   - Automatic cleanup on error
   - File handle management

9. **Concurrent Primitives**: Thread-safe operations
   - MVars for mutable shared state
   - Chans for message passing
   - Software Transactional Memory (STM) if possible
   - Thread pools for parallel execution

10. **Native Integration**: Expose C++ I/O efficiently
    - Direct memory mapping for large files
    - Zero-copy I/O where possible
    - Async I/O with io_uring or similar
