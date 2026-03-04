# Bootstrap Verification

## 4-Stage Bootstrap Process
1. **Stage 1**: Stock `elm` compiler builds `guida.js` via `./scripts/build.sh bin` (XHR IO)
2. **Stage 2**: `guida.js` self-compiles with kernel IO via `./scripts/build-self.sh bin` → `eco-boot.js`
3. **Stage 3**: `eco-boot.js` compiles itself → `eco-boot-2.js` (needs runner script that calls `Elm.Terminal.Main.init()`)
4. **Stage 4**: `eco-boot-2.js` compiles itself → `eco-boot-3.js` (must be identical to eco-boot-2.js = fixed point)

## Running eco-boot.js
eco-boot.js does NOT auto-start. It exports via `_Platform_export` and requires a runner:
```js
#!/usr/bin/env node
const { Elm } = require("./eco-boot.js");
Elm.Terminal.Main.init();
```
Command: `node bin/eco-boot-runner.js make --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp --output=bin/eco-boot-2.js /work/compiler/src/Terminal/Main.elm`

Note: `--local-package` path must point to package ROOT (where elm.json lives), not the `src/` subdirectory.

## Kernel JS Conventions (eco-kernel-cpp)
- Multi-arg functions called via `A2`/`A3`/`AN` MUST be wrapped with matching `F2`/`F3`/`FN`
- Single-arg functions called directly (e.g., `_File_readString(path)`) should NOT have F wrappers
- Functions returning Elm Lists must use `__List_fromArray(jsArray)`
- Functions returning Unit must use `__Utils_Tuple0` (not `0`)
- Function arity in JS must match the call site in compiled output, NOT hypothetical Elm signatures
- To verify: grep for call sites in compiled eco-boot.js (e.g., `A2(_MVar_put, ...)` means F2 needed)

## Fixed Bugs (2026-03)
- `_MVar_read`, `_MVar_take`, `_MVar_put` had spurious `typeTag` parameter not passed by Elm code
- `_Console_write` and other multi-arg functions missing FN wrappers
- `_Env_rawArgs` returned raw JS array instead of Elm List
- Unit values used `0` instead of `__Utils_Tuple0`
