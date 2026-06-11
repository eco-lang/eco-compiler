# Vendored Node-API (N-API) headers

Verbatim copies of the C Node-API headers from the Node.js project
(also published standalone as the `nodejs/node-api-headers` project):

- `node_api.h`
- `node_api_types.h`
- `js_native_api.h`
- `js_native_api_types.h`

These four files are self-contained: `node_api.h` only includes
`js_native_api.h` and `node_api_types.h`, and those only include
`js_native_api_types.h`.

## Provenance

- Origin: Node.js / node-api-headers (https://github.com/nodejs/node-api-headers)
- Copied from: `/usr/include/node/` of Node.js **v22.22.3**
- License: **MIT** (Copyright Node.js contributors)

## Usage in eco

eco's Node.js glue (`runtime/src/embed/eco_node_addon.cpp`) compiles against
these headers with `#define NAPI_VERSION 8` (see line 24 of that file). Any
future update of this vendored copy MUST still support **NAPI >= 8**.
