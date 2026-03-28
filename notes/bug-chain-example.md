  Summary: one bug, three views, full pipeline trace
                                                                                                                     
  All 3 POST_010 failures are the same underlying bug — standalone accessor type-variable scoping at
  Specialize.elm:2107-2133 — manifested across two control-flow forms (case, if) and two container patterns (tuple of
   accessors, tuple of accessor+lambda).                          
                                                                                                                     
  The full pipeline trace from POST_010 to CGEN_005:              

  POST_010 detects:  orphan TVars ["a","c"] on Case/If node                                                          
                     (accessor extension vars not resolved against record type)                                      
           ↓                                                                                                         
  Monomorphization:  applySubstCan on accessor's canonical type                                                      
                     → MVar(negId) for unresolved vars (not in substitution)                                         
           ↓                                                                                                         
  MLIR codegen:      computeRecordLayout sees MVar → canUnbox(MVar) = False                                          
                     → accessor's eco.project.record gets result type !eco.value                                     
           ↓                                                      
  CGEN_005 detects:  eco.construct.record has unboxed_bitmap=0x3 (field IS unboxed)                                  
                     but eco.project.record has result !eco.value (field treated as boxed)                           
                     → REP_BOUNDARY_001 violation                                                                    
                                                                                                                     
  POST_010 catches the root cause at the type-checking stage. CGEN_005 catches the downstream symptom at MLIR        
  codegen. They are the same bug seen at different pipeline stages.
