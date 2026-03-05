# MonoCase Decider Traversal Pattern

## Key Issue
The `Decider MonoChoice` tree inside `MonoCase` contains `Leaf (Inline MonoExpr)` leaves that hold full MonoExpr expressions. These expressions can contain any AST node (MonoDestruct, MonoVarLocal, MonoLet, etc.).

**Any function that traverses the MonoExpr tree MUST also recurse into MonoCase decider trees**, specifically into `Inline` leaves. Otherwise, expressions inside the decider are silently skipped.

## Functions that need decider traversal (MonoInlineSimplify.elm)
- `substitute` → `substituteDecider`
- `countUsages` → `countUsagesInDecider`  
- `inlineVar` → `inlineVarInDecider`
- `rewriteExpr` → `rewriteDecider`
- `simplifyLets` → `simplifyLetsDecider`

## Similarly: MonoDestruct path traversal
`MonoPath` nodes (MonoRoot, MonoIndex, MonoField, MonoUnbox) contain variable names at the leaf (`MonoRoot name type`). Functions that rename or count variable references must traverse paths:
- `substitute` → `substitutePath` (already existed)
- `countUsages` → `countUsagesInPath` (already existed)
- `inlineVar` → `inlineVarInPath` (added — note: can only update MonoRoot when replacement is MonoVarLocal)
- `findFreeLocals` → `findPathFreeLocals` (already existed in Closure.elm)
- `collectVarTypes` → `collectPathVarTypes` (added to Closure.elm)
