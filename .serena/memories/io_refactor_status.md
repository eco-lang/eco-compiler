# IO Refactor Status

## Completed
- All 13 legacy handlers migrated from `bin/index.js` to `eco-io-handler.js`
- Only 2 legacy handlers remain: `getArchive`, `httpUpload` (intentionally bundled network ops)
- `Eco.XHR` extended with `sendBytesTask` and `rawBytesRecvTask` for binary transport
- `Eco.MVar` rewritten with proper byte encoder/decoder parameters (XHR API diverges from kernel)
- `Eco.Process` extended with `spawnProcess` (direct pipe, stream handle registry)
- `Eco.Runtime` extended with `loadState`
- `System/IO.elm` is now the centralized IO module with all operations
- `Utils/Main.elm` re-exports IO functions for backward compat (callers not yet migrated)
- Backward-compatible aliases: hPutStr→write, putStrLn→printLn, getLine→readLine, etc.

## Binary dispatch in eco-io
- Single `eco-io` URL for JSON and binary requests
- `X-Eco-Op` header presence distinguishes binary from JSON
- `handleEcoIOBinary` handles: `File.writeBytes`, `MVar.put`

## MVar in eco-io-handler.js
- Full MVar semantics with `wakeUpMVarWaiters` function
- Stores opaque ArrayBuffer values server-side
- Waiter queues for read/take/put blocking

## Stream handles
- `streamHandles` registry in eco-io-handler.js (IDs start at 1000)
- Console.write and File.close expanded to check stream handles
- Used by Process.spawnProcess for child stdin pipes
