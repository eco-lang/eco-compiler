Corrected Analysis                                                                                                                            
                                                                                                                                                
  You're right to question this. Let me clarify what's actually happening.                                                                      
  
  The programs DO pass type checking. Both runToMono and runToMonoDirect call the same runToPostSolve → runToTypeCheck pipeline. If there were  
  Error descriptors in the solver state after type checking, toCanTypeBatch (called inside Solve.runWithIds at line 121) would crash for BOTH 
  pipelines — but only MonoDirect crashes.

  The Error descriptors are created by MonoDirect itself, during forced unification in SolverSnapshot.specializeChainedWithSubst. Here's the
  mechanism:

  1. MonoDirect takes a clean snapshot of the solver state (no Error descriptors)
  2. For each specialization, it creates a local copy via snapshotToIoState
  3. It calls walkAndUnify for each (tvar, monoType) pair on the specStack
  4. walkAndUnify → unifyVarWithMono → Unify.unify modifies the local copy
  5. When multiple specStack constraints modify shared type variables in conflicting ways, Unify.unify sets them to Error

  The specific issue for cycles/let-rec with Def nodes (non-tail-recursive mutual recursion): funcDefInfo returns Nothing for the tvar of Def
  (only TailDef has a tvar). This means the cycle function's own type constraint is never added to the cycleStack:

  -- specializeCycle, line 1839-1842:
  cycleStack =
      case requestedTvar of
          Just tvar -> ( tvar, requestedMonoType ) :: state.specStack
          Nothing -> state.specStack  -- ← Def nodes hit this branch

  Then specializeDefForInstance calls specializeChainedWithSubst with innerStack containing the function's tvar constraint plus the stale
  specStack from the outer context. The outer specStack constraints modify shared variables in the local state in a way that conflicts with the
  function body's internal type structure, producing Error descriptors on nested variables.

  I confirmed this empirically: changing Error -> crash ... to Error -> State.pure Can.TUnit eliminates all 4 crashes. The tests then produce
  type mismatches instead (12 failures, same count — crashes converted to wrong-type failures), confirming that MonoDirect is resolving types
  incorrectly for these cycle constructs, and the Error descriptors are a symptom of that incorrect resolution.

