# Plan: Remove Guida Syntax Support

## Overview

Remove Guida syntax support entirely and keep only Elm syntax. This involves eliminating the `SyntaxVersion` type and simplifying all code paths.

## Summary of Guida-Specific Syntax Features to Remove

| Feature | Example | Location |
|---------|---------|----------|
| Underscores in numbers | `1_000_000` | `Parse/Number.elm` |
| Binary literals | `0b1010` | `Parse/Number.elm` |
| Named wildcards | `_foo` pattern | `Parse/Pattern.elm` |
| Extended record updates | `{ expr | field = val }` | `Parse/Expression.elm` |
| Tuples > 3 elements | `(a, b, c, d)` | `Canonicalize/*.elm` |

## Files to Modify

### 1. DELETE ENTIRELY

| File | Reason |
|------|--------|
| `compiler/src/Compiler/AST/SyntaxVersion.elm` | Core definition - no longer needed |
| `compiler/src/Compiler/Parse/SyntaxVersion.elm` | Re-export wrapper - no longer needed |

### 2. PARSER FILES — Remove SyntaxVersion Parameter

| File | Functions Affected |
|------|-------------------|
| `compiler/src/Compiler/Parse/Module.elm` | `fromByteString`, `chompModule`, `checkModule`, `chompDecls`, `chompDeclsHelp` |
| `compiler/src/Compiler/Parse/Declaration.elm` | `declaration`, `valueDecl` |
| `compiler/src/Compiler/Parse/Expression.elm` | ~40 functions |
| `compiler/src/Compiler/Parse/Pattern.elm` | ~15 functions |
| `compiler/src/Compiler/Parse/String.elm` | `character`, `chompChar`, `string`, `singleString`, `multiString`, `eatEscape`, `eatUnicode` |
| `compiler/src/Compiler/Parse/Number.elm` | ~15 functions |

### 3. CANONICALIZATION FILES — Remove SyntaxVersion Parameter

| File | Functions Affected |
|------|-------------------|
| `compiler/src/Compiler/Canonicalize/Module.elm` | `canonicalizeValues`, plus internal helpers |
| `compiler/src/Compiler/Canonicalize/Expression.elm` | ~15 functions |
| `compiler/src/Compiler/Canonicalize/Pattern.elm` | ~10 functions |
| `compiler/src/Compiler/Canonicalize/Type.elm` | `toAnnotation`, `canonicalize`, `canonicalizeFields`, `canonicalizeType` |
| `compiler/src/Compiler/Canonicalize/Effects.elm` | `canonicalize`, `canonicalizePort` |
| `compiler/src/Compiler/Canonicalize/Environment/Local.elm` | `addAliases`, `addAlias`, `canonicalizeAlias`, `canonicalizeUnion`, `canonicalizeCtor` |

### 4. ERROR REPORTING — Remove SyntaxVersion Parameter

| File | Functions Affected |
|------|-------------------|
| `compiler/src/Compiler/Reporting/Error.elm` | `toReports` |
| `compiler/src/Compiler/Reporting/Error/Syntax.elm` | ~25 functions |

### 5. AST/SOURCE — Remove SyntaxVersion from ModuleData

| File | Change |
|------|--------|
| `compiler/src/Compiler/AST/Source.elm` | Remove `syntaxVersion` field from `ModuleData` |

### 6. BUILDER FILES — Remove .guida Support

| File | Changes |
|------|---------|
| `compiler/src/Builder/Elm/Details.elm` | Remove `.guida` file crawling |
| `compiler/src/Builder/Elm/Outline.elm` | Remove `.guida` partition logic |
| `compiler/src/Builder/Build.elm` | Remove `.guida` file handling |

### 7. TERMINAL/CLI FILES

| File | Changes |
|------|---------|
| `compiler/src/Terminal/Terminal/Helpers.elm` | Rename `guidaOrElmFile` to `elmFile`, remove `.guida` support |
| `compiler/src/Terminal/Main.elm` | Update help text, use `elmFile` |
| `compiler/src/Terminal/Test.elm` | Remove `.guida` from filter |
| `compiler/src/Terminal/Repl.elm` | Use Elm parser directly |
| `compiler/src/Terminal/Format.elm` | Remove SV usage |

### 8. API FILES

| File | Changes |
|------|---------|
| `compiler/src/API/Main.elm` | Use Elm parser directly |
| `compiler/src/API/Format.elm` | Use Elm directly |

### 9. FORMAT FILES

| File | Changes |
|------|---------|
| `compiler/src/Common/Format.elm` | Remove `SyntaxVersion` parameter |
| `compiler/src/Common/Format/Render/Box.elm` | Use Elm parsing directly |

## Implementation Order

1. Delete SyntaxVersion definition files
2. Update all imports and remove SyntaxVersion parameters
3. Keep only Elm branches in all case expressions
4. Update builder/terminal code to remove `.guida` file handling
5. Clean up error messages
6. Run tests
