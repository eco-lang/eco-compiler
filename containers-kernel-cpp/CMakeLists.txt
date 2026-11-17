cmake_minimum_required(VERSION 3.16)
project(eco-containers LANGUAGES CXX)

# Kernels of the public eco/containers package (SeqDict and SeqSet): one static library per kernel
# module, named EcoContainers_<Module>. The module list is ECO_CONTAINERS_MODS in
# runtime/src/codegen/CMakeLists.txt, which also feeds the AOT link line (EcoBootConfig.h), the
# eco-boot-native dependencies and the bundle install rules, as ECO_SYSTEM_MODS does for eco/system.
#
# The kernels use elm/core's headers: FNV walks heap values the way Utils.cpp's `==` does (and shares
# core/SeqDict.hpp with it), and JsArray2 forwards to the JsArray kernel.

set(RUNTIME_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../runtime/src)
set(ELM_KERNEL_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../elm-kernel-cpp/src)

function(eco_containers_module mod)
    add_library(EcoContainers_${mod} STATIC ${ARGN})
    target_include_directories(EcoContainers_${mod} PUBLIC
        ${ELM_KERNEL_INCLUDE_DIR}
        ${RUNTIME_INCLUDE_DIR})
    target_compile_features(EcoContainers_${mod} PUBLIC cxx_std_20)
    if(ECO_ASSERTS_ON)
        target_compile_options(EcoContainers_${mod} PRIVATE -UNDEBUG)
    endif()
endfunction()

eco_containers_module(FNV src/eco-containers/FNVExports.cpp)
eco_containers_module(JsArray2 src/eco-containers/JsArray2Exports.cpp)
