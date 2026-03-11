# Fix: Details caching ignores needsTypedOpt flag

## Problem

`handleCachedDetails` in `Details.elm` returns cached details when `elm.json`
hasn't changed, completely ignoring the `needsTypedOpt` flag. This means
Stage 5 (MLIR output, `needsTypedOpt=True`) reuses details cached by
Stage 2 (JS output, `needsTypedOpt=False`), so packages are never rebuilt
with `typed-artifacts.dat`. Monomorphization then crashes with
"Missing union for ctor shape" because the GlobalTypeEnv is empty for those
packages.

## Fix

Store `hasTypedOpt : Bool` in `DetailsData` (and thus in `d.dat`). When
`handleCachedDetails` finds cached details where `hasTypedOpt=False` but the
current build needs `needsTypedOpt=True`, re-generate instead of returning
the cached details.

### Changes

1. **`DetailsData`** — add `hasTypedOpt : Bool` field
2. **`detailsEncoder` / `detailsDecoder`** — encode/decode the new field
   (old d.dat files without the field will fail to decode, which triggers
   `generate` via the `Nothing` branch — safe fallback)
3. **`handleCachedDetails`** — when `detailsData.time == newTime`, also
   check `needsTypedOpt && not detailsData.hasTypedOpt`; if so, call
   `generate` instead of returning cached
4. **`verifyApp` / `verifyPkg`** — set `hasTypedOpt` in the Details record
   from the env's `needsTypedOpt` value
