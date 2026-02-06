Report: Staging Logic Distribution Between Monomorphize and GlobalOpt                                                                         
                                                                                                                                                
  Executive Summary                                                                                                                             
                                                                                                                                                
  Finding: Staging and uncurrying logic is currently spread across THREE phases (Monomorphize, GlobalOpt, and MLIR codegen), when it should be  
  consolidated primarily in GlobalOpt. The Monomorphize phase is doing more than pure type specialization - it's also creating closure wrappers 
  based on staging decisions.                                                                                                                   
                                                                                                                                                
  ---                                                                                                                                           
  1. Current Phase Responsibilities                                                                                                             
                                                                                                                                                
  Monomorphize Phase (Current)                                                                                                                  
  ┌─────────────────────────────────────────────────────────────────────────┬─────────────────────────────┐                                     
  │                             Responsibility                              │      Is This Correct?       │                                     
  ├─────────────────────────────────────────────────────────────────────────┼─────────────────────────────┤                                     
  │ Type specialization (substitution)                                      │ ✅ Yes                      │                                     
  ├─────────────────────────────────────────────────────────────────────────┼─────────────────────────────┤                                     
  │ Closure capture computation                                             │ ✅ Yes                      │                                     
  ├─────────────────────────────────────────────────────────────────────────┼─────────────────────────────┤                                     
  │ Creating closure wrappers via ensureCallableTopLevel                    │ ❌ Should move to GlobalOpt │                                     
  ├─────────────────────────────────────────────────────────────────────────┼─────────────────────────────┤                                     
  │ Staging-aware wrapper creation (using stageParamTypes, stageReturnType) │ ❌ Should move to GlobalOpt │                                     
  ├─────────────────────────────────────────────────────────────────────────┼─────────────────────────────┤                                     
  │ Kernel ABI type derivation                                              │ ⚠ Questionable             │                                     
  └─────────────────────────────────────────────────────────────────────────┴─────────────────────────────┘                                     
  GlobalOpt Phase (Current)                                                                                                                     
  ┌──────────────────────────────────────────────┬──────────────────┐                                                                           
  │                Responsibility                │ Is This Correct? │                                                                           
  ├──────────────────────────────────────────────┼──────────────────┤                                                                           
  │ Type flattening (canonicalizeClosureStaging) │ ✅ Yes           │                                                                           
  ├──────────────────────────────────────────────┼──────────────────┤                                                                           
  │ ABI normalization (normalizeCaseIfAbi)       │ ✅ Yes           │                                                                           
  ├──────────────────────────────────────────────┼──────────────────┤                                                                           
  │ ABI wrapper generation (buildAbiWrapperGO)   │ ✅ Yes           │                                                                           
  ├──────────────────────────────────────────────┼──────────────────┤                                                                           
  │ Staging validation (validateClosureStaging)  │ ✅ Yes           │                                                                           
  ├──────────────────────────────────────────────┼──────────────────┤                                                                           
  │ Return arity annotation                      │ ✅ Yes           │                                                                           
  └──────────────────────────────────────────────┴──────────────────┘                                                                           
  MLIR Codegen (Current)                                                                                                                        
  ┌──────────────────────────────────────────────────────────┬───────────────────────────────────────────┐                                      
  │                      Responsibility                      │             Is This Correct?              │                                      
  ├──────────────────────────────────────────────────────────┼───────────────────────────────────────────┤                                      
  │ Reading staging from types (stageArity, stageReturnType) │ ⚠ Should be pre-computed                 │                                      
  ├──────────────────────────────────────────────────────────┼───────────────────────────────────────────┤                                      
  │ Stage-by-stage call dispatch (applyByStages)             │ ⚠ Should be simpler with canonical types │                                      
  └──────────────────────────────────────────────────────────┴───────────────────────────────────────────┘                                      
  ---                                                                                                                                           
  2. Evidence of Misplaced Code                                                                                                                 
                                                                                                                                                
  2.1 Closure Wrapper Creation in Monomorphize                                                                                                  
                                                                                                                                                
  File: compiler/src/Compiler/Monomorphize/Closure.elm                                                                                          
                                                                                                                                                
  The function ensureCallableTopLevel (lines 53-106) creates closure wrappers and uses staging helpers:                                         
                                                                                                                                                
  ensureCallableTopLevel expr monoType state =                                                                                                  
      case monoType of                                                                                                                          
          Mono.MFunction _ _ ->                                                                                                                 
              let                                                                                                                               
                  -- Use stage arity (first MFunction params only) for wrapper creation.                                                        
                  stageArgTypes =                                                                                                               
                      Mono.stageParamTypes monoType    -- ❌ STAGING LOGIC                                                                      
                                                                                                                                                
                  stageRetType =                                                                                                                
                      Mono.stageReturnType monoType   -- ❌ STAGING LOGIC                                                                       
              in                                                                                                                                
              ...                                                                                                                               
                  makeAliasClosure                    -- ❌ WRAPPER CREATION                                                                    
                      (Mono.MonoVarGlobal region specId monoType)                                                                               
                      region                                                                                                                    
                      stageArgTypes                                                                                                             
                      stageRetType                                                                                                              
                      monoType                                                                                                                  
                      state                                                                                                                     
                                                                                                                                                
  Called from Specialize.elm at 5 locations:                                                                                                    
  - Line 192: In specializeNode for TOpt.Define                                                                                                 
  - Line 211: In specializeNode for TOpt.TrackedDefine                                                                                          
  - Line 284: In specializeNode for TOpt.TailDefine                                                                                             
  - Line 297: In specializeNode for TOpt.TrackedTailDefine                                                                                      
  - Line 467: In specializeExpr for lambda expressions                                                                                          
                                                                                                                                                
  2.2 buildNestedCalls Defined in Monomorphize, Used Only by GlobalOpt                                                                          
                                                                                                                                                
  File: compiler/src/Compiler/Monomorphize/Closure.elm (lines 230-266)                                                                          
                                                                                                                                                
  buildNestedCalls region calleeExpr params =                                                                                                   
      let                                                                                                                                       
          calleeType =                                                                                                                          
              Mono.typeOf calleeExpr                                                                                                            
                                                                                                                                                
          srcSeg =                                                                                                                              
              Mono.segmentLengths calleeType          -- ❌ STAGING LOGIC                                                                       
                                                                                                                                                
          -- Build calls stage by stage                                                                                                         
          buildCalls currentCallee remainingArgs segLengths =                                                                                   
              ...                                                                                                                               
                          resultType =                                                                                                          
                              Mono.stageReturnType currentCalleeType  -- ❌ STAGING LOGIC                                                       
                                                                                                                                                
  Only caller: GlobalOpt/MonoGlobalOptimize.elm:651                                                                                             
                                                                                                                                                
  This function is mislocated - it's defined in Monomorphize but only used by GlobalOpt.                                                        
                                                                                                                                                
  2.3 Staging Helpers Usage Distribution                                                                                                        
  ┌──────────────────────────────────┬─────────────────┬─────────────────┬────────────────┐                                                     
  │             Location             │ stageParamTypes │ stageReturnType │ segmentLengths │                                                     
  ├──────────────────────────────────┼─────────────────┼─────────────────┼────────────────┤                                                     
  │ Monomorphize/Closure.elm         │ 1               │ 2               │ 1              │                                                     
  ├──────────────────────────────────┼─────────────────┼─────────────────┼────────────────┤                                                     
  │ GlobalOpt/MonoGlobalOptimize.elm │ 2               │ 1               │ 3              │                                                     
  ├──────────────────────────────────┼─────────────────┼─────────────────┼────────────────┤                                                     
  │ GlobalOpt/MonoReturnArity.elm    │ 1               │ 0               │ 0              │                                                     
  ├──────────────────────────────────┼─────────────────┼─────────────────┼────────────────┤                                                     
  │ Generate/MLIR/Functions.elm      │ 0               │ 1               │ 0              │                                                     
  ├──────────────────────────────────┼─────────────────┼─────────────────┼────────────────┤                                                     
  │ Generate/MLIR/Expr.elm           │ 0               │ 2               │ 0              │                                                     
  └──────────────────────────────────┴─────────────────┴─────────────────┴────────────────┘                                                     
  Total: 4 calls in Monomorphize, 6 calls in GlobalOpt, 3 calls in MLIR codegen                                                                 
                                                                                                                                                
  ---                                                                                                                                           
  3. Code to Move from Monomorphize to GlobalOpt                                                                                                
                                                                                                                                                
  3.1 Primary Candidate: ensureCallableTopLevel                                                                                                 
                                                                                                                                                
  Current location: compiler/src/Compiler/Monomorphize/Closure.elm:53-106                                                                       
                                                                                                                                                
  Why it belongs in GlobalOpt:                                                                                                                  
  - Creates closure wrappers based on staging decisions                                                                                         
  - Uses stageParamTypes and stageReturnType                                                                                                    
  - Is fundamentally about "code shaping" rather than "type specialization"                                                                     
  - Creates the closures that GlobalOpt later canonicalizes                                                                                     
                                                                                                                                                
  Proposed approach: Remove calls to ensureCallableTopLevel from Specialize.elm. GlobalOpt should create any needed closure wrappers during its 
  ABI normalization pass.                                                                                                                       
                                                                                                                                                
  3.2 Secondary Candidates                                                                                                                      
  ┌────────────────────┬──────────────────┬──────────────────────────────────────────┐                                                          
  │      Function      │ Current Location │           Recommended Location           │                                                          
  ├────────────────────┼──────────────────┼──────────────────────────────────────────┤                                                          
  │ buildNestedCalls   │ Closure.elm:230  │ MonoGlobalOptimize.elm                   │                                                          
  ├────────────────────┼──────────────────┼──────────────────────────────────────────┤                                                          
  │ makeAliasClosure   │ Closure.elm:134  │ MonoGlobalOptimize.elm (or shared utils) │                                                          
  ├────────────────────┼──────────────────┼──────────────────────────────────────────┤                                                          
  │ makeGeneralClosure │ Closure.elm:178  │ MonoGlobalOptimize.elm (or shared utils) │                                                          
  └────────────────────┴──────────────────┴──────────────────────────────────────────┘                                                          
  3.3 Shared Utilities to Keep in Monomorphize                                                                                                  
  ┌────────────────────────┬────────────────────────────────────┐                                                                               
  │        Function        │           Reason to Keep           │                                                                               
  ├────────────────────────┼────────────────────────────────────┤                                                                               
  │ computeClosureCaptures │ Both phases need capture analysis  │                                                                               
  ├────────────────────────┼────────────────────────────────────┤                                                                               
  │ freshParams            │ Both phases need param generation  │                                                                               
  ├────────────────────────┼────────────────────────────────────┤                                                                               
  │ extractRegion          │ Both phases need region extraction │                                                                               
  ├────────────────────────┼────────────────────────────────────┤                                                                               
  │ flattenFunctionType    │ Both phases need type flattening   │                                                                               
  └────────────────────────┴────────────────────────────────────┘                                                                               
  ---                                                                                                                                           
  4. Impact on MLIR Codegen                                                                                                                     
                                                                                                                                                
  Currently MLIR codegen uses staging helpers (stageArity, stageReturnType) directly. If GlobalOpt canonicalizes all types to flat form, MLIR   
  codegen becomes simpler:                                                                                                                      
                                                                                                                                                
  Before (with nested types):                                                                                                                   
  -- MLIR/Expr.elm:1054-1058                                                                                                                    
  stageN =                                                                                                                                      
      Mono.stageArity funcMonoType                                                                                                              
                                                                                                                                                
  stageRetType =                                                                                                                                
      Mono.stageReturnType funcMonoType                                                                                                         
                                                                                                                                                
  After (with flat types):                                                                                                                      
  -- With flat MFunction [a, b, c] result, stage arity = length [a, b, c]                                                                       
  stageN =                                                                                                                                      
      case funcMonoType of                                                                                                                      
          MFunction args _ -> List.length args                                                                                                  
          _ -> 0                                                                                                                                
                                                                                                                                                
  The applyByStages function in MLIR codegen becomes simpler because there's only one "stage" - the flat param list.                            
                                                                                                                                                
  ---                                                                                                                                           
  5. Specific Recommendations                                                                                                                   
                                                                                                                                                
  Recommendation 1: Remove ensureCallableTopLevel from Specialize                                                                               
                                                                                                                                                
  Impact:                                                                                                                                       
  - Specialize.elm would no longer create closure wrappers                                                                                      
  - Raw MonoVarGlobal and MonoVarKernel expressions would pass through                                                                          
  - GlobalOpt would be responsible for wrapping them                                                                                            
                                                                                                                                                
  Risk: Medium - Requires ensuring GlobalOpt handles all cases that ensureCallableTopLevel currently handles.                                   
                                                                                                                                                
  Recommendation 2: Move buildNestedCalls to GlobalOpt                                                                                          
                                                                                                                                                
  Impact:                                                                                                                                       
  - Code consolidation - staging logic in one place                                                                                             
  - Clearer phase boundaries                                                                                                                    
                                                                                                                                                
  Risk: Low - Function is already only used by GlobalOpt.                                                                                       
                                                                                                                                                
  Recommendation 3: Consider Moving Kernel ABI Logic to GlobalOpt                                                                               
                                                                                                                                                
  Current state: KernelAbi.elm derives kernel types during Monomorphize.                                                                        
                                                                                                                                                
  Question: Should kernel calling conventions be decided in GlobalOpt instead?                                                                  
                                                                                                                                                
  Risk: Higher - Kernel ABI affects type derivation during specialization.                                                                      
                                                                                                                                                
  ---                                                                                                                                           
  6. Architectural Principles                                                                                                                   
                                                                                                                                                
  Ideal Phase Responsibilities:                                                                                                                 
  Phase: Monomorphize                                                                                                                           
  Responsibility: Type substitution, closure capture analysis, translating TOpt → Mono AST                                                      
  Does NOT Do: Staging decisions, ABI decisions, closure wrapper creation                                                                       
  ────────────────────────────────────────                                                                                                      
  Phase: GlobalOpt                                                                                                                              
  Responsibility: Type canonicalization, ABI normalization, closure wrapper creation, staging enforcement                                       
  Does NOT Do: Type specialization                                                                                                              
  ────────────────────────────────────────                                                                                                      
  Phase: MLIR Codegen                                                                                                                           
  Responsibility: Iterate over Mono AST and emit MLIR                                                                                           
  Does NOT Do: Type analysis, staging decisions                                                                                                 
  Key Principle: Monomorphize should produce a "naive" Mono AST where types faithfully represent Elm's curried semantics. GlobalOpt then shapes 
  this into what the backend needs.                                                                                                             
                                                                                                                                                
  ---                                                                                                                                           
  7. Summary                                                                                                                                    
  ┌────────────────────────────────────────┬──────────┬───────────────────────────────┐                                                         
  │                 Issue                  │ Severity │        Fix Complexity         │                                                         
  ├────────────────────────────────────────┼──────────┼───────────────────────────────┤                                                         
  │ ensureCallableTopLevel in Monomorphize │ High     │ Medium                        │                                                         
  ├────────────────────────────────────────┼──────────┼───────────────────────────────┤                                                         
  │ buildNestedCalls in wrong module       │ Medium   │ Low                           │                                                         
  ├────────────────────────────────────────┼──────────┼───────────────────────────────┤                                                         
  │ MLIR codegen using staging helpers     │ Low      │ Low (after GlobalOpt changes) │                                                         
  └────────────────────────────────────────┴──────────┴───────────────────────────────┘                                                         
  The current architecture has staging logic spread across three phases. To achieve the goal of "staging-agnostic Monomorphize", the primary    
  action is removing ensureCallableTopLevel calls from Specialize.elm and letting GlobalOpt handle all closure wrapper creation.   

===

To bring staging logic and calling convention decision all within a single compiler phase, GlobalOpt, what steps need to be taken ?
