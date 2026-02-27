# Migrate Remaining Legacy Network Handlers to eco-io

## Context

After the eco-io migration (phases 1-8), three legacy XHR handlers remain in
`compiler/bin/index.js`. All three are network operations that go through
mock-xmlhttprequest with dedicated or default handlers.

The Elm side calls these through `Utils/Impure.elm`, which wraps `Http.task`
from elm/http. The mock-xmlhttprequest library intercepts all XHR from the
compiled Elm code and dispatches to server handlers registered in `index.js`.

## Decisions

1. **Http.fetch error handling:** Return errors properly with status codes.
   The Elm side reports them through the existing error handling path.
2. **Redirect following:** getArchive follows redirects (current behavior).
   Http.fetch does not.
3. **Publish error types:** Remove from Exit.elm.

## Implementation Plan

### Phase 1: Migrate Default Handler → eco-io `Http.fetch`

**Elm side:**

1. Create `compiler/src-xhr/Eco/Http.elm` with:
   ```elm
   fetch : String -> String -> List ( String, String ) -> Task Never (Result Http.Error String)
   ```
   Sends `{ op: "Http.fetch", args: { method, url, headers } }` via eco-io.
   Returns `Ok body` on 2xx, `Err error` otherwise.

2. Update `Builder/Http.elm:fetch` to use `Eco.Http.fetch` instead of
   `Impure.customTask`. Map errors through the existing `(Error -> e)`
   parameter that is currently ignored.

**JS side:**

3. Add `Http.fetch` handler to `eco-io-handler.js`:
   - Makes real HTTP/HTTPS request using Node.js `http`/`https`
   - Handles gzip/deflate decompression
   - Returns `{ value: body }` on 2xx
   - Returns `{ error: { statusCode: N, url: "..." } }` on non-2xx

4. Remove `server.setDefaultHandler(...)` from `index.js`.

### Phase 2: Remove `publish` command and `httpUpload`

5. Delete `compiler/src/Terminal/Publish.elm`.

6. `Terminal/Main.elm`: Remove import, remove `publish` from command list,
   remove the `publish` command definition function.

7. `Builder/Http.elm`: Remove `upload`, `MultiPart` type, `filePart`,
   `jsonPart`, `stringPart` from exports and implementation.

8. `Builder/Reporting/Exit.elm`: Remove `Publish` error type (~30
   constructors), `publishToReport`, and any `Publish` branches in
   pattern matches.

9. `index.js`: Remove `server.post("httpUpload", ...)`, remove `form-data`
   and `FormData` imports.

### Phase 3: Migrate getArchive → eco-io `Http.getArchive`

10. Add `getArchive` to `Eco.Http`:
    ```elm
    getArchive : String -> Task Never (Result String { sha : String, archive : List { relativePath : String, data : String } })
    ```

11. Update `Builder/Http.elm:getArchive` to use `Eco.Http.getArchive`.

12. Move getArchive handler logic (and `download` helper) from `index.js`
    into `eco-io-handler.js`. Follows redirects.

13. Remove `server.post("getArchive", ...)` and `download` from `index.js`.

### Phase 4: Clean up

14. Remove `Utils/Impure.elm`.

15. `index.js` should now contain only:
    - `require` of eco-io-handler
    - `server.post("eco-io", ...)` handler
    - `server.install()`
    - `require("./guida.js")` and `Elm.Terminal.Main.init()`

16. Rebuild and test:
    - `npm run build:bin`
    - `cd compiler && npx elm-test-rs --fuzz 1`
    - `cmake --build build --target clean && cmake --build build --target check`
