add_subdirectory(include/toy)

set(LLVM_LINK_COMPONENTS
  Support
)

set(_TBLGEN_INC_DIRS
        "${CMAKE_CURRENT_SOURCE_DIR}/include"  # the folder with Ops.td
        ${MLIR_INCLUDE_DIRS}
        ${LLVM_INCLUDE_DIRS}
)
set(_TBLGEN_I_ARGS)
foreach(dir IN LISTS _TBLGEN_INC_DIRS)
    list(APPEND _TBLGEN_I_ARGS -I "${dir}")
endforeach()

set(LLVM_TARGET_DEFINITIONS src/mlir/ToyCombine.td)
mlir_tablegen(ToyCombine.inc -gen-rewriters ${_TBLGEN_I_ARGS})
add_public_tablegen_target(ToyCh7CombineIncGen)

add_toy_chapter(toyc-ch7
  SOURCES
    src/toyc.cpp
    src/mlir/Dialect.cpp
    src/mlir/MLIRGen.cpp
    src/mlir/ToyCombine.cpp
    src/mlir/ShapeInferencePass.cpp
    src/mlir/LowerToAffineLoops.cpp
    src/mlir/LowerToLLVM.cpp
    src/parser/AST.cpp
  LIBS
    # Optional: add extra MLIR/LLVM libs this chapter needs
    # e.g., MLIRParser, MLIRPass, MLIRTransforms
  DEPENDS
    ToyCh7OpsIncGen
    ToyCh7CombineIncGen
    ToyCh7ShapeInferenceInterfaceIncGen
)

include_directories(include/)
include_directories(${CMAKE_CURRENT_BINARY_DIR}/include/)

get_property(dialect_libs GLOBAL PROPERTY MLIR_DIALECT_LIBS)
get_property(conversion_libs GLOBAL PROPERTY MLIR_CONVERSION_LIBS)
get_property(extension_libs GLOBAL PROPERTY MLIR_EXTENSION_LIBS)
target_link_libraries(toyc-ch7
        PRIVATE
        ${dialect_libs}
        ${conversion_libs}
        ${extension_libs}
        MLIRAnalysis
        MLIRBuiltinToLLVMIRTranslation
        MLIRCallInterfaces
        MLIRCastInterfaces
        MLIRExecutionEngine
        MLIRFunctionInterfaces
        MLIRIR
        MLIRLLVMCommonConversion
        MLIRLLVMDialect
        MLIRLLVMDialect
        MLIRLLVMToLLVMIRTranslation
        MLIRMemRefDialect
        MLIRParser
        MLIRPass
        MLIRSideEffectInterfaces
        MLIRSupport
        MLIRTargetLLVMIRExport
        MLIRTransforms
)