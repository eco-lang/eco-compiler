# Elm Documentation Preview Workflow

## Purpose
Run elm-doc-preview to find and fix documentation errors in the Elm codebase.

## Running elm-doc-preview

### Important: Must run from build-xhr/
elm-doc-preview needs both `elm.json` (application) and `elm-application.json` (package metadata)
in the same directory. The `build-xhr/` directory has both.

### Start Preview Server (Background)
```bash
cd /work/compiler/build-xhr && npx elm-doc-preview -p 8000 --no-browser
```
Access at: http://localhost:8000/packages/the-sett/eco-compiler/1.0.0/

### Check for Documentation Errors
The most reliable way to see doc errors is to run with `--output`:
```bash
cd /work/compiler/build-xhr && npx elm-doc-preview --output /tmp/docs-preview.json 2>&1
```

### How it works internally
elm-doc-preview reads `elm.json` (type: application), then merges `elm-application.json`
(name, version, exposed-modules) from the same directory. It creates a temp package,
symlinks source files, and runs `elm make --docs`.

### Manual docs generation (faster for debugging)
Create a temp package dir and use `elm make --docs` directly - see buildApplicationDocs
in elm-doc-server.js for the format.

This will show errors like:
```
-- DOCS MISTAKE ----------------- src/Compiler/AST/Monomorphized.elm

I do not see `ContainerKind` in your module documentation, but it is in your
`exposing` list:

12|     , ContainerKind(..)
          ^^^^^^^^^^^^^
Add a line like `@docs ContainerKind` to your module documentation!
```

## Common Documentation Errors

### "I do not see X in your module documentation"
**Problem**: A type/function is in the `exposing` list but not documented with `@docs`

**Solution**: Add a `@docs TypeName` line to the module documentation comment.

Example fix - add a new section to the module doc:
```elm
{-| Module description...

# Existing Section

@docs ExistingType


# New Section

@docs NewType   <-- Add this

-}
```

## Verification
After fixes, run the `--output` command again. Success looks like:
```
elm-doc-preview 6.0.1 using elm 0.19.1
Previewing the-sett/eco-compiler 1.0.0 from /work/compiler
  |> building /work/compiler documentation
  |> writing documentation into /tmp/docs-preview.json
```
(No error messages means all docs are valid)
