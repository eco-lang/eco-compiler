# Code Readability Refactoring Plan

This document describes the refactoring needed to improve code readability by eliminating lines over 200 characters, flattening nested monadic code, and extracting named functions.

## Design Principles

### The Barbell Strategy
Code should be concentrated in one of two forms:
1. **Pipeline functions** - Long flat chains of `|> andThen` operations
2. **Step functions** - Named functions implementing individual pipeline steps

Avoid the middle ground of many small functions that each contain just one `.andThen` joining two other functions.

### Flattening Pattern
Transform nested lambdas:
```elm
-- Before (nested)
thing
    |> Thing.andThen (\outer -> f outer |> ThingCons
        |> Thing.andThen (\inner -> g outer inner |> ThingCons)
    )

-- After (flat with context passing)
thing
    |> Thing.andThen (\outer -> { inner = f outer, outer = outer } |> ThingCons)
    |> Thing.andThen (\{inner, outer} -> g outer inner |> ThingCons)
```

### Naming Conventions
- Extract lambdas into named top-level functions with descriptive names
- Names should describe what the function does, not how
- Comments can be added to explain complex logic

---

## Summary by Category

| Category | Files | Long Lines | Primary Pattern |
|----------|-------|------------|-----------------|
| Parse modules | 5 | ~15 | Nested tuple construction in lambdas |
| Error reporting | 9 | ~60 | String literals (not monadic) |
| Generate/Optimize | 5 | ~8 | Complex type signatures + funType nesting |
| Builder modules | 5 | ~20 | Deep Task.bind nesting with MVars |
| Common/Terminal | 8 | ~22 | Mixed: imports, strings, nested lambdas |

**Total: ~125 lines requiring attention**

---

## Phase 1: Parser Modules (High Impact)

### Files
- `src/Compiler/Parse/Type.elm`
- `src/Compiler/Parse/Declaration.elm`
- `src/Compiler/Parse/Module.elm`
- `src/Compiler/Parse/Pattern.elm`
- `src/Compiler/Parse/Expression.elm`

### Common Pattern: Nested Tuple Construction in Lambdas

**Problem:**
```elm
|> P.bind (\( trailingComments, fields ) ->
    P.addEnd start (Src.TRecord fields (Just ( ( initialComments, postNameComments ), name )) trailingComments))
```

**Solution:** Extract record/constructor building into named functions:
```elm
buildRecordWithName : A.Position -> Comments -> Comments -> Name -> Comments -> Fields -> P.Parser Src.Type
buildRecordWithName start initialComments postNameComments name trailingComments fields =
    P.addEnd start (Src.TRecord fields (Just ( ( initialComments, postNameComments ), name )) trailingComments)

-- Usage:
|> P.bind (\( trailingComments, fields ) ->
    buildRecordWithName start initialComments postNameComments name trailingComments fields)
```

### Specific Refactorings

#### Type.elm (3 long lines)
| Line | Current | Refactoring |
|------|---------|-------------|
| 93 | Nested record construction | Extract `buildRecordWithName` |
| 109-110 | Complex field entry | Extract `buildRecordWithoutName` + intermediate `let` binding |

#### Declaration.elm (4 long lines)
| Line | Current | Refactoring |
|------|---------|-------------|
| 104 | 8-param function call | Extract type annotation into `let` binding |
| 476 | Long type signature | Create type aliases: `TypeAnnotationInfo`, `DefArgsResult` |
| 695 | Port construction | Extract `buildPortDecl` function |
| 772 | Infix construction | Extract `buildInfix` function |

#### Module.elm (3 long lines)
| Line | Current | Refactoring |
|------|---------|-------------|
| 520 | Manager construction | Extract into `let` binding before `P.fmap` |
| 1513 | Import construction | Extract `buildImportWithAlias` |
| 1533 | Maybe.map in import | Extract mapping and import construction |

#### Pattern.elm (1 long line)
| Line | Current | Refactoring |
|------|---------|-------------|
| 345 | Alias pattern construction | Extract `buildAliasPattern` |

#### Expression.elm (7 long lines)
| Line | Current | Refactoring |
|------|---------|-------------|
| 299 | Update construction | Extract `buildRecordUpdate` |
| 308, 375 | Field entry construction | Extract field entry into `let` binding |
| 2825, 2844 | If expression | Extract `buildConditionPair`, `buildThenBranchPair` |
| 3066 | Type annotation | Extract into `let` binding |
| 3077 | Long type signature | Create type aliases |

---

## Phase 2: Builder Modules (High Impact)

### Files
- `src/Builder/Build.elm`
- `src/Builder/Elm/Details.elm`
- `src/Builder/Deps/Solver.elm`
- `src/Builder/Elm/Outline.elm`

### Common Pattern: Deep Task.bind Nesting with MVars

**Problem:** 15+ levels of indentation with nested `Task.bind` chains:
```elm
Task.bind (\_ ->
    Task.bind (Utils.mapTraverse identity compare (Utils.readMVar statusDecoder))
              (Utils.readMVar statusDictDecoder mvar))
```

**Solution:** Extract MVar reading patterns into named helpers:
```elm
readStatusDict : MVar StatusDict -> Task Never (Dict String ModuleName.Raw Status)
readStatusDict mvar =
    Utils.readMVar statusDictDecoder mvar
        |> Task.bind (Utils.mapTraverse identity compare (Utils.readMVar statusDecoder))

-- Usage:
|> Task.bind (\_ -> readStatusDict mvar)
```

### Specific Refactorings

#### Build.elm (13 long lines - HIGHEST PRIORITY)
| Line | Current | Refactoring |
|------|---------|-------------|
| 163, 251 | MVar reading chain | Extract `readStatusesFromDict` |
| 178, 266 | forkWithKey deeply nested | Extract `forkCheckModules` |
| 272, 275, 281 | Root checking pipeline | Extract `checkAndCompileRoots`, `readAllRootResults` |
| 635 | 10-param function | Create `DepsAccumulator` record type |
| 981, 1069 | 13-param compile functions | Create `CompileContext`, `FileContext` records |
| 1437, 1446 | REPL finalization | Extract `readAndFinalizeRepl` |

#### Details.elm (6 long lines)
| Line | Current | Refactoring |
|------|---------|-------------|
| 445 | Nested Dict operations | Extract `gatherDirectForeigns` |
| 630 | Composed fork operation | Extract `startCrawl` |
| 635 | Double Task.bind | Extract `readAllStatuses` |
| 647, 651 | MVar result reading | Extract `readAllResults` |

#### Solver.elm (1 long line)
| Line | Current | Refactoring |
|------|---------|-------------|
| 132 | Repeated Dict type | Create `PkgVersionDict` type alias |

#### Outline.elm (1 long line)
| Line | Current | Refactoring |
|------|---------|-------------|
| 52 | 4 repeated Dict types | Create `DependencyMap` type alias |

---

## Phase 3: Generate/Optimize Modules (Medium Impact)

### Files
- `src/Compiler/Optimize/TypedModule.elm`
- `src/Compiler/Elm/Docs.elm`
- `src/Compiler/Generate/JavaScript.elm`
- `src/Compiler/Generate/JavaScript/SourceMap.elm`
- `src/Compiler/Type/Constrain/Module.elm`

### Common Pattern: Complex Type Signatures + Nested funType

**Problem:**
```elm
Type.funType (router msg1 self1) (Type.funType (effectList home cmd msg1) (Type.funType state1 (task state1)))
```

**Solution:** Extract type constructors as named functions:
```elm
buildCmdEffectsType : IO.Canonical -> Name -> Type -> Type -> Type -> Type
buildCmdEffectsType home cmd msg1 self1 state1 =
    Type.funType (router msg1 self1)
        (Type.funType (effectList home cmd msg1)
            (Type.funType state1 (task state1)))
```

### Specific Refactorings

#### TypedModule.elm (2 long lines)
| Line | Current | Refactoring |
|------|---------|-------------|
| 372 | Complex nested param types | Create `MaybeTypedArgs` type alias |
| 411 | Similar + monadic chain | Extract `optimizeNoArgs`, `optimizeWithTypedArgs`, `optimizeWithUntypedArgs` |

#### Docs.elm (1 long line)
| Line | Current | Refactoring |
|------|---------|-------------|
| 591 | 6 Dict fields in constructor | Create type aliases for each Dict type, or convert to record |

#### JavaScript.elm (1 long line)
| Line | Current | Refactoring |
|------|---------|-------------|
| 184 | Embedded JS string | Extract into named string fragments: `colorSwitch`, `printFunction`, etc. |

#### SourceMap.elm (1 long line)
| Line | Current | Refactoring |
|------|---------|-------------|
| 103 | Complex pattern destructuring | Create `SegmentData`, `PreviousState` type aliases + helper extractors |

#### Constrain/Module.elm (3 long lines)
| Line | Current | Refactoring |
|------|---------|-------------|
| 217, 220, 223 | 4-level funType nesting | Extract `buildCmdEffectsType`, `buildSubEffectsType`, `buildFxEffectsType` |

---

## Phase 4: Error Reporting (Low Priority - Strings Only)

### Files
All files in `src/Compiler/Reporting/Error/`

### Pattern: Long String Literals

**These are NOT monadic nesting issues.** All 60+ long lines are error message strings.

**Solution:** Extract long strings into module-level constants:
```elm
argumentTypeOrderingHint : String
argumentTypeOrderingHint =
    "I always figure out the argument types from left to right. "
        ++ "If an argument is acceptable, I assume it is \"correct\" and move on. "
        ++ "So the problem may actually be in one of the previous arguments!"

-- Usage:
[ D.toSimpleHint argumentTypeOrderingHint ]
```

**Files affected:**
- `Error/Type.elm` - 2 lines
- `Error/Canonicalize.elm` - 13 lines
- `Error/Json.elm` - 3 lines
- `Error/Syntax.elm` - 28+ lines (most affected)
- `Error/Main.elm` - 2 lines
- `Error/Pattern.elm` - 2 lines
- `Error/Import.elm` - 2 lines
- `Error/Docs.elm` - 2 lines

**Estimated effort:** 2-3 hours to extract ~60 message constants

---

## Phase 5: Terminal/Common Modules (Mixed)

### Files
- `src/Terminal/Main.elm`
- `src/Terminal/Repl.elm`
- `src/Terminal/Test.elm`
- `src/Terminal/Init.elm`
- `src/Common/Format/Cheapskate/Inlines.elm`
- `src/Common/Format/Cheapskate/Parse.elm`
- `src/Common/Format/ImportInfo.elm`

### Mixed Patterns

#### Terminal/Main.elm (6 long lines - help text)
Extract help text strings into named constants:
```elm
debugDesc : String
debugDesc =
    "Turn on the time-travelling debugger. It allows you to rewind and replay events. "
        ++ "The events can be imported/exported into a file, which makes for very precise bug reports!"
```

#### Terminal/Repl.elm (1 long line - composed monadic chain)
| Line | Current | Refactoring |
|------|---------|-------------|
| 603 | Triple `<<` composition | Extract `generateOutput` function |

#### Terminal/Test.elm (2 long lines)
| Line | Current | Refactoring |
|------|---------|-------------|
| 244 | Long regex | Break into logical parts with `++` |
| 259 | Pipeline with inline case | Extract `handleCheckDefinition` |

#### Terminal/Init.elm (1 long line)
| Line | Current | Refactoring |
|------|---------|-------------|
| 120 | Nested `<|` lambdas | Convert to `Task.bind` pipeline |

#### Inlines.elm (1 long line - import)
Break long import into multi-line format.

#### Parse.elm (2 long lines - nested bind)
Extract intermediate parsers with names.

#### ImportInfo.elm (1 long line - lambda)
Extract lambda into named function `addExposed`.

---

## Implementation Order

### Priority 1: Builder Modules
**Reason:** These have the deepest nesting (15+ levels) and most severe readability issues.
1. `Build.elm` - 13 lines, core build system
2. `Details.elm` - 6 lines, dependency handling

### Priority 2: Parser Modules
**Reason:** High impact on understanding the parser.
1. `Expression.elm` - 7 lines, most complex
2. `Declaration.elm` - 4 lines
3. `Module.elm` - 3 lines
4. `Type.elm` - 3 lines
5. `Pattern.elm` - 1 line

### Priority 3: Generate/Optimize
**Reason:** Critical for MLIR backend work.
1. `Constrain/Module.elm` - 3 lines, complex type building
2. `TypedModule.elm` - 2 lines, new typed optimization

### Priority 4: Terminal/Common
**Reason:** User-facing but lower complexity.
1. `Repl.elm`, `Test.elm`, `Init.elm` - monadic issues
2. `Main.elm` - help text extraction

### Priority 5: Error Reporting
**Reason:** Purely cosmetic, no logic changes.
- All Error/* files - string extraction only

---

## Questions for Resolution

1. **Type alias naming:** Should type aliases be placed in the same module or in a shared `Types.elm` module?
   - Recommendation: Same module unless used across 3+ files

2. **Record vs tuple for context passing:** When flattening pipelines, prefer records `{outer, inner}` or tuples `(outer, inner)`?
   - Recommendation: Records for 3+ fields, tuples for 2

3. **Helper function placement:** Should extracted helper functions be placed immediately before their caller, or grouped at module end?
   - Recommendation: Group by functionality, with pipeline function first followed by its helpers

4. **Naming convention for MVar readers:** Use pattern `readXFromY` or `readY` or `getX`?
   - Recommendation: `readStatusDict`, `readAllResults` pattern

5. **Error string organization:** Extract to same file or create `ErrorMessages.elm` module?
   - Recommendation: Same file, grouped at top with clear section comment

---

## Estimated Effort

| Phase | Files | Lines | Hours |
|-------|-------|-------|-------|
| Phase 1: Parsers | 5 | 18 | 4-5 |
| Phase 2: Builder | 4 | 21 | 5-6 |
| Phase 3: Generate | 5 | 8 | 2-3 |
| Phase 4: Errors | 9 | 60 | 2-3 |
| Phase 5: Terminal | 7 | 13 | 2-3 |
| **Total** | **30** | **~120** | **15-20** |

---

## Success Criteria

1. No lines exceed 200 characters
2. Maximum nesting depth of 4 levels for monadic chains
3. All extracted functions have descriptive names
4. Pipeline functions are clearly structured as flat chains
5. Code compiles and all tests pass after each phase
