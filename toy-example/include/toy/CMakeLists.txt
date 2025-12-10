set(_TBLGEN_INC_DIRS
        "${CMAKE_CURRENT_SOURCE_DIR}/.."  # the folder with toy/*.td
        ${MLIR_INCLUDE_DIRS}
        ${LLVM_INCLUDE_DIRS}
)
set(_TBLGEN_I_ARGS)
foreach(dir IN LISTS _TBLGEN_INC_DIRS)
    list(APPEND _TBLGEN_I_ARGS -I "${dir}")
endforeach()

set(LLVM_TARGET_DEFINITIONS Ops.td)
mlir_tablegen(Ops.h.inc -gen-op-decls ${_TBLGEN_I_ARGS})
mlir_tablegen(Ops.cpp.inc -gen-op-defs ${_TBLGEN_I_ARGS})
mlir_tablegen(Dialect.h.inc -gen-dialect-decls ${_TBLGEN_I_ARGS})
mlir_tablegen(Dialect.cpp.inc -gen-dialect-defs ${_TBLGEN_I_ARGS})
add_public_tablegen_target(ToyCh7OpsIncGen)

# Most dialects should use add_mlir_interfaces().
set(LLVM_TARGET_DEFINITIONS ShapeInferenceInterface.td)
mlir_tablegen(ShapeInferenceOpInterfaces.h.inc -gen-op-interface-decls ${_TBLGEN_I_ARGS})
mlir_tablegen(ShapeInferenceOpInterfaces.cpp.inc -gen-op-interface-defs ${_TBLGEN_I_ARGS})
add_public_tablegen_target(ToyCh7ShapeInferenceInterfaceIncGen)
