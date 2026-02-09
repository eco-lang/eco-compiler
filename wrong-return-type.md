  Investigation Report: Wrong Return Type for Kernel Wrapper Basics_add_$_1                                          
                                                                                                                     
  Summary                                                                                                            
                                                                                                                     
  After implementing call-site specialization for number-boxed kernels, the tests no longer crash with               
  SIGSEGV/SIGABRT. However, they produce wrong output (sum: 67108895 instead of sum: 10).                            
                                                                                                                     
  The generated MLIR for Basics_add_$_1 shows:                                                                       
  - CORRECT: Input types are (i64, i64)                                                                              
  - CORRECT: Uses eco.int.add intrinsic                                                                              
  - WRONG: Return type is (!eco.value) instead of (i64)                                                              
  - WRONG: Result is boxed before returning                                                                          
                                                                                                                     
  Evidence from MLIR Output                                                                                          
                                                                                                                     
  "func.func"() ({                                                                                                   
      ^bb0(%arg0: i64, %arg1: i64):                                                                                  
        %2 = "eco.int.add"(%arg0, %arg1) : (i64, i64) -> i64   // <-- Intrinsic produces i64                         
        %3 = "eco.box"(%2) : (i64) -> !eco.value              // <-- WRONG: boxes to !eco.value                      
        "eco.return"(%3) : (!eco.value) -> ()                  // <-- WRONG: returns !eco.value                      
    }) {function_type = (i64, i64) -> (!eco.value), sym_name = "Basics_add_$_1", ...}                                
                                                                                                                     
  Root Cause Hypothesis                                                                                              
                                                                                                                     
  The issue is in how the kernel wrapper lambda's return type is determined during MLIR codegen.                     
                                                                                                                     
  In compiler/src/Compiler/Generate/MLIR/Expr.elm:757, when creating a PendingLambda:                                
  pendingLambda =                                                                                                    
      { ...                                                                                                          
      , returnType = Mono.typeOf body  -- <-- This determines the function's return type                             
      , ...                                                                                                          
      }                                                                                                              
                                                                                                                     
  Then in compiler/src/Compiler/Generate/MLIR/Lambdas.elm:118-119:                                                   
  actualResultType : MlirType                                                                                        
  actualResultType =                                                                                                 
      Types.monoTypeToAbi lambda.returnType                                                                          
                                                                                                                     
  If lambda.returnType is somehow MVar _ CEcoValue or similar instead of MInt, then monoTypeToAbi would return       
  !eco.value.                                                                                                        
                                                                                                                     
  Investigation Gap                                                                                                  
                                                                                                                     
  I traced the flow through:                                                                                         
  1. Monomorphization (Specialize.elm): deriveKernelAbiType with call-site substitution                              
  2. GlobalOpt (MonoGlobalOptimize.elm): ensureCallableForNode → makeAliasClosureGO for kernel wrappers              
  3. MLIR Codegen (Expr.elm, Lambdas.elm): PendingLambda creation and function generation                            
                                                                                                                     
  The expected flow should produce MInt as the return type, but somewhere this is getting lost or overridden.        
                                                                                                                     
  Key Code Locations                                                                                                 
  ┌────────────────────────┬───────────┬───────────────────────────────────────────────────────────┐                 
  │          File          │   Line    │                        Description                        │                 
  ├────────────────────────┼───────────┼───────────────────────────────────────────────────────────┤                 
  │ Specialize.elm         │ 1961-1998 │ deriveKernelAbiType - call-site aware type derivation     │                 
  ├────────────────────────┼───────────┼───────────────────────────────────────────────────────────┤                 
  │ MonoGlobalOptimize.elm │ 751-765   │ ensureCallableForNode for MonoVarKernel                   │                 
  ├────────────────────────┼───────────┼───────────────────────────────────────────────────────────┤                 
  │ MonoGlobalOptimize.elm │ 648-674   │ makeAliasClosureGO - creates wrapper closure              │                 
  ├────────────────────────┼───────────┼───────────────────────────────────────────────────────────┤                 
  │ Expr.elm               │ 751-759   │ PendingLambda creation with returnType = Mono.typeOf body │                 
  ├────────────────────────┼───────────┼───────────────────────────────────────────────────────────┤                 
  │ Lambdas.elm            │ 118-119   │ actualResultType = Types.monoTypeToAbi lambda.returnType  │                 
  └────────────────────────┴───────────┴───────────────────────────────────────────────────────────┘                 
  Next Steps to Complete Investigation                                                                               
                                                                                                                     
  1. Add debug logging to deriveKernelAbiType to verify it returns MFunction [MInt] (MFunction [MInt] MInt) for      
  Basics.add in Int context                                                                                          
  2. Verify flattenFunctionType produces ([MInt, MInt], MInt) when given the kernel's ABI type                       
  3. Trace makeAliasClosureGO to confirm retType = MInt is passed correctly                                          
  4. Check Mono.typeOf for the call expression inside the wrapper to verify it returns the correct type              
  5. Inspect the generated PendingLambda before it's processed by generateLambdaFunc to confirm returnType field     
  value                                                                                                              
                                                                                                                     
  Possible Root Causes                                                                                               
                                                                                                                     
  1. Substitution not applied correctly: The number type variable might not be properly resolved to MInt in the      
  call-site substitution                                                                                             
  2. Type computed from wrong source: The return type might be derived from the kernel's CANONICAL type instead of   
  the MONOMORPHIC type                                                                                               
  3. GlobalOpt transformation issue: The closure wrapper might be using the wrong return type from                   
  flattenFunctionType                                                                                                
  4. Naming mismatch: The function name Basics_add_$_1 suggests it's a lambda/closure (not Elm_Kernel_Basics_add), so
   the wrapper closure path is being taken - need to verify this wrapper has the correct return type                 
                                                                                                      
