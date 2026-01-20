# Fix Unicode Character Literal Code Generation

## Problem Statement

Character literals with Unicode escapes (e.g., `'\u{03BB}'` for λ) produce incorrect code point values in MLIR output.

**Test case**: `CharUnicodeTest.elm`
```elm
_ = Debug.log "code1" (Char.toCode '\u{03BB}')  -- Expected: 955, Actual: 92
_ = Debug.log "code2" (Char.toCode '\u{20AC}')  -- Expected: 8364, Actual: 92
```

## Root Cause

The parser stores character literals as **JS-style escape sequences** (designed for JavaScript output), but the MLIR code generator assumes the string contains the **actual character**.

**Data flow:**
1. Parser sees: `'\u{03BB}'`
2. Parser stores: `"\u03BB"` (6-character string: `\`, `u`, `0`, `3`, `B`, `B`)
3. MLIR codegen (`Expr.elm:252-254`) does:
   ```elm
   codepoint =
       String.uncons value
           |> Maybe.map (Tuple.first >> Char.toCode)
           |> Maybe.withDefault 0
   ```
4. `String.uncons "\u03BB"` returns `Just ('\\', "u03BB")`
5. `Char.toCode '\\'` = 92 (backslash)

The JS codegen doesn't have this problem because it outputs `"\u03BB"` directly to JavaScript, which interprets it correctly.

## Escape Sequence Formats

The parser produces these escape formats in character/string values:

| Input | Stored Value | Notes |
|-------|--------------|-------|
| `'a'` | `"a"` | Plain character |
| `'\n'` | `"\n"` | Simple escape (actual newline OR `\` + `n`) |
| `'\''` | `"\'"` | Escaped single quote |
| `'\u{03BB}'` | `"\u03BB"` | 4-digit Unicode escape (BMP) |
| `'\u{1F648}'` | `"\uD83D\uDE48"` | Surrogate pair (outside BMP) |

## Proposed Solution

Add a `decodeCharLiteral` function in `Compiler.Generate.MLIR.Expr` to decode the JS escape sequence and extract the actual code point.

### Implementation Steps

1. **Create escape sequence decoder** in `Expr.elm`:
   ```elm
   import Hex
   import Utils.Crash exposing (crash)

   decodeCharLiteral : String -> Int
   decodeCharLiteral value =
       case String.uncons value of
           Just ( '\\', rest ) ->
               decodeEscape rest

           Just ( c, _ ) ->
               Char.toCode c

           Nothing ->
               crash "decodeCharLiteral: empty character literal"

   decodeEscape : String -> Int
   decodeEscape rest =
       case String.uncons rest of
           Just ( 'u', hex ) ->
               decodeUnicodeEscape hex

           Just ( 'n', _ ) -> 10   -- newline
           Just ( 'r', _ ) -> 13   -- carriage return
           Just ( 't', _ ) -> 9    -- tab
           Just ( '"', _ ) -> 34   -- double quote
           Just ( '\'', _ ) -> 39  -- single quote
           Just ( '\\', _ ) -> 92  -- backslash

           Just ( c, _ ) ->
               crash ("decodeCharLiteral: unknown escape \\" ++ String.fromChar c)

           Nothing ->
               crash "decodeCharLiteral: trailing backslash"

   decodeUnicodeEscape : String -> Int
   decodeUnicodeEscape hex =
       -- Parse \uXXXX format, handle surrogate pairs
       case Hex.fromString (String.toLower (String.left 4 hex)) of
           Ok code ->
               if code >= 0xD800 && code <= 0xDBFF then
                   -- High surrogate - need to decode pair
                   decodeSurrogatePair code (String.dropLeft 6 hex)
               else
                   code

           Err _ ->
               crash ("decodeCharLiteral: invalid hex in \\u" ++ String.left 4 hex)

   decodeSurrogatePair : Int -> String -> Int
   decodeSurrogatePair hi rest =
       -- rest should be "XXXX" (after "\u")
       case Hex.fromString (String.toLower (String.left 4 rest)) of
           Ok lo ->
               0x10000 + ((hi - 0xD800) * 0x400) + (lo - 0xDC00)

           Err _ ->
               crash ("decodeCharLiteral: invalid low surrogate in pair")
   ```

2. **Update `LChar` handling** in `Expr.elm:245-263`:
   ```elm
   Mono.LChar value ->
       let
           ( var, ctx1 ) =
               Ctx.freshVar ctx

           codepoint : Int
           codepoint =
               decodeCharLiteral value

           ( ctx2, op ) =
               Ops.arithConstantChar ctx1 var codepoint
       in
       { ops = [ op ]
       , resultVar = var
       , resultType = Types.ecoChar
       , ctx = ctx2
       }
   ```

3. **Add unit tests** in `tests/Compiler/Generate/CodeGen/`:
   - Test ASCII character: `'a'` → 97
   - Test simple escape: `'\n'` → 10
   - Test BMP Unicode: `'\u{03BB}'` → 955
   - Test emoji (surrogate pair): `'\u{1F648}'` → 128584

## Files to Modify

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `decodeCharLiteral` and update `LChar` handling |

## Testing Strategy

1. **Unit test**: New test file `CharLiteralCodeGenTest.elm` testing character literal code generation
2. **E2E test**: Verify `CharUnicodeTest.elm` passes (expects code1: 955, code2: 8364)

## Resolved Questions

1. **Simple escapes**: Verified - `'\n'` stores as `"\n"` (backslash + n), so decoder must handle all escape types.

2. **Hex module**: `rtfeldman/elm-hex` is already installed. Import as `Hex`.

3. **Location**: Inline in `Expr.elm` is acceptable for now.

4. **Error handling**: Use `Utils.Crash.crash "message"` for malformed cases since parsing has already validated the input. This should never happen in practice.

## Alternatives Considered

1. **Change the parser to store actual characters**: Would require changes to the parser and potentially break JS codegen. Not recommended.

2. **Store both representations**: Would require AST changes across many modules. Over-engineered for this issue.

3. **Decode at an earlier phase (e.g., Monomorphize)**: Could work but the decode is only needed for MLIR, not JS. Best to keep it localized.
