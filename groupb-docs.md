# Group A/B Documentation Update List

Expressions that were previously Group B (handled by PostSolve structural type computation)
are now Group A (solver-owned via `recordNodeVar`).

**Old Group A:** Int, Negate, Binop, Call, If, Case, Access, Update
**Old Group B:** Str, Chr, Float, Unit, List, Tuple, Record, Lambda, Accessor, Let, LetRec, LetDestruct, Shader

**New Group A:** Int, Negate, Binop, Call, If, Case, Access, Update, **Accessor, List, Tuple, Record, Lambda, Let, LetRec, LetDestruct**
**New Group B:** Str, Chr, Float, Unit, Shader (and leaf Var* forms which don't need either treatment)

---

## Production Code

### 1. `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm`
- **Line 360-362**: Comment says "Group A expressions (those with natural result variables)" and "Group B expressions (without natural result variables)". **Change:** Update to reflect that List, Tuple, Record, Lambda, Accessor, Let/LetRec/LetDestruct are now Group A with recorded node vars.
- **Line 369**: Comment `-- Group A: Use specialized helpers that record the natural result var`. **Change:** Still correct for the original Group A, no change needed.
- **Line 394**: Comment `-- Group A: treat .field accessor as Group A with recorded node var`. **Change:** Already correct.
- **Line 398**: Comment `-- Group A: containers and lambdas with recorded node vars`. **Change:** Already correct.
- **Line 411**: Comment `-- Group A: let expressions with recorded node vars`. **Change:** Already correct.
- **Line ~420**: Comment `-- Group B: Use generic path with synthetic exprVar`. **Change:** Update to say Group B is now only Str, Chr, Float, Unit, Shader, and the various Var* leaf forms.

### 2. `compiler/src/Compiler/Type/PostSolve.elm`
- **Line 3**: Module doc `fixing Group B expression types`. **Change:** Narrow to say "fixing remaining Group B expression types (Str, Chr, Float, Unit, Shader)".
- **Line 8**: `Fix "missing" types for Group B expressions (those with unconstrained synthetic vars)`. **Change:** Narrow Group B list.
- **Line 40**: `nodeTypes: Expression/pattern types from the solver (Group B entries are unconstrained)`. **Change:** Most former Group B entries now have solver types; only Str/Chr/Float/Unit/Shader remain unconstrained.
- **Line 44**: `nodeTypes: Fixed node types with Group B expressions properly typed`. **Change:** Same narrowing.
- **Line 342-345**: Comment listing Group A and Group B. **Change:** Move List, Tuple, Record, Lambda, Accessor, Let* from Group B to Group A.
- **Line 887**: `Handle List expression (Group B)`. **Change:** Now Group A (solver provides type), but PostSolve may still recurse into children. Could say "Handle List expression (now Group A, recurse children)".
- **Line 939**: `Handle Tuple expression (Group B)`. **Change:** Same.
- **Line 999**: `Handle Record expression (Group B)`. **Change:** Same.
- **Line 1059**: `Handle Lambda expression (Group B)`. **Change:** Same.
- **Line 1115**: `Handle Accessor expression (Group B)`. **Change:** Same.

## Design Documents

### 3. `design_docs/theory/pass_post_solve_theory.md`
- **Line 5**: "fixing incomplete types for Group B expressions". **Change:** Narrow.
- **Line 13**: Section header "Problem 1: Group B Expression Types". **Change:** Update scope.
- **Line 17-18**: Lists Group A and Group B members explicitly. **Change:** Move List, Tuple, Record, Lambda, Accessor, Let/LetRec/LetDestruct from B to A. Group B becomes: Str, Chr, Float, Unit, Shader.
- **Line 46**: "fixing Group B types". **Change:** Narrow.
- **Line 51**: `Group A: Trust solver's type`. **Change:** Now includes more forms.
- **Line 60**: `Group B: Compute type structurally`. **Change:** Now fewer forms.
- **Line 207**: "All Group B expressions have concrete types". **Change:** Narrow list.

### 4. `design_docs/invariants.csv`
- **Line 90**: Section header `# POST-SOLVE PHASE - Fix Group B types`. **Change:** Narrow.
- **Line 93** (POST_001): Lists Group B as "lists tuples records units and lambdas". **Change:** Remove lists, tuples, records, lambdas from Group B. Group B is now Str, Chr, Float, Unit, Shader.
- **Line 99** (POST_004): "For Group B expressions the structurally computed PostSolve types". **Change:** Narrow Group B scope.
- **Lines 105, 109** (POST_007, POST_009): Reference Group B lambdas. **Change:** Lambdas are now Group A; these invariants may need rewording to say "for lambda nodes" without the Group B qualifier.

### 5. `design_docs/invariant-test-logic.md`
- **Lines 290-301** (TYPE_007): Lists Group A and Group B members. **Change:** Move Accessor, List, Tuple, Record, Lambda, Let/LetRec/LetDestruct from Group B to Group A. Group B becomes: Str, Chr, Float, Unit, Shader.
- **Line 345, 350**: "Every Group A node variable". **Change:** Now covers more expression kinds.
- **Line 376-384** (POST_001): "Group B expressions get structural types" listing "lists, tuples, records, units, lambdas". **Change:** Narrow to Str, Chr, Float, Unit, Shader.
- **Line 412** (POST_004): "PostSolve is deterministic for Group B". **Change:** Narrow scope.
- **Lines 491, 502** (POST_008): "Group B lambda". **Change:** Lambda is now Group A.
- **Line 516** (POST_009): "Group B". **Change:** Narrow.
- **Line 610** (POST_010): "TYPE_007 checks pre-PostSolve bare TVars on Group A nodes". **Change:** Group A now includes more forms.

### 6. `THEORY.md`
- **Line 328**: `Fix Group B expression types`. **Change:** Narrow.
- **Line 367**: Lists Group B as "Literals (String, Float), containers (List, Tuple, Record), and lambdas". **Change:** Remove containers and lambdas from Group B.
- **Line 614**: `POST_001-004 | Group B type fixing`. **Change:** Narrow scope.

## Test Code

### 7. `compiler/tests/TestLogic/Type/NodeVarConstrained.elm`
- **Lines 9-11**: Doc says "Group A expressions are those dispatched to specialised constraint helpers". **Change:** Add Accessor, List, Tuple, Record, Lambda, Let/LetRec/LetDestruct to the Group A list.
- **Lines 19-20**: "Group B expressions (Str, Chr, Float, Unit, List, Tuple, Record, Lambda, Accessor, Let/LetRec/LetDestruct)". **Change:** Remove the moved kinds. Group B is now: Str, Chr, Float, Unit, Shader.
- **Line 48**: "every Group A expression's node type". **Change:** Now covers more kinds.
- **Line 134**: "checking Group A nodes inside the body". **Change:** Already generic enough.
- **Line 205**: Comment `-- Check this node if it's a Group A expression`. **Change:** Already correct (the dispatch handles this).
- **Line 241**: Comment `-- Group B or leaf — not checked by TYPE_007`. **Change:** Group B is now smaller.

### 8. `compiler/tests/TestLogic/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`
- **Line 9**: "Group B expressions are: Str, Chr, Float, Unit, List, Tuple, Record, Lambda, Accessor". **Change:** Remove List, Tuple, Record, Lambda, Accessor from this list.
- **Lines 45-46**: Test name "POST_001: Group B Structural Types". **Change:** May need scoping note.
- **Lines 66-74**: Filters to "Group B expressions that were synthetic" using `isGroupBExprNode`. **Change:** The filter function needs updating.

### 9. `compiler/tests/TestLogic/Type/PostSolve/PostSolveInvariantHelpers.elm`
- **Lines 283-295**: `isGroupBExprNode` function and its doc. **Change:** Remove List, Tuple, Record, Lambda, Accessor from the True cases. These are now Group A.

### 10. `compiler/tests/TestLogic/Type/PostSolve/GroupBTypes.elm`
- **Lines 3-5, 18, 47**: References to "GroupB types" including "lists, tuples, records, units, lambdas". **Change:** Narrow to Str, Chr, Float, Unit, Shader.

### 11. `compiler/tests/TestLogic/Type/PostSolve/PostSolvePlaceholderVarsTest.elm`
- **Lines 6, 13, 92-93, 118, 143**: References to "Group B expressions" and "Group B nodes with no pre-type". **Change:** Narrow Group B scope.

### 12. `compiler/tests/TestLogic/TestPipeline.elm`
- **Line 34**: "PostSolve: Fix Group B types". **Change:** Narrow.

### 13. `compiler/tests/TestLogic/Type/PostSolve/Determinism.elm`
- **Line 22**: "PostSolve is deterministic for Group B and kernels". **Change:** Narrow Group B.

## Serena Memories

### 14. `.serena/memories/compiler_pipeline.md`
- **Line 11**: "PostSolve (fix Group B types, infer kernel types)". **Change:** Narrow.
- **Line 31**: "Fixes Group B expression types (Str, List, Lambda, etc.)". **Change:** Remove List, Lambda.

## Plans (historical, lower priority)

### 15. Various plan files under `/work/plans/`
These are historical implementation plans. Lower priority but should be annotated if touched:
- `type-post-solver.md` (lines 6, 25, 29, 47-48, 133, 137, 309, 313, 357-371, 408, 415)
- `type-all-exprs-group-ab.md` (throughout — this is the original design doc for the A/B split)
- `post-001-003-synthetic-provenance-invariants.md` (lines 18, 23, 75, 89, etc.)
- `post-001-lambda-accessor-extension.md` (throughout)
- `strengthen-postsolve-invariant-tests.md` (lines 15, 72)
- `post-solve-non-regression-invariants.md` (line 31)
- `invariant-test-modules.md` (lines 33, 206-208)
- `stubbed-test-logic-implementation.md` (lines 285, 518-526, 687)

### 16. Old design docs under `/work/old_design_docs/`
- `type-all-exprs-rethink.md` (throughout — the original Group A/B design)
- `type-post-solver.md` (lines 4, 35, 53, 184, 267, 304, 782, 794-796, 820)
