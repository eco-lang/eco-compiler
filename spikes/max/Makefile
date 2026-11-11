# Builds the MAX spikes against the eco dev build tree (cmake --preset build) and the MAX venv that
# setup.sh makes. Source env.sh first: the binaries need its variables at run time.
#
#   make            everything below
#   make run-capi   hand-written mo text through the C API
#   make run-bytes  an eco .so and libmax in one process, zero-copy Bytes ports
#   make run-mnist  train and evaluate the MNIST network (FORMAT=bytecode|generic|text)
#   make check-bytecode  the MNIST graphs' Elm-written bytecode against their generic text
#   make run-churn  the eco-only repro of the MNIST run's memory growth (MODE=hold|both|...)
#
# Elm programs are compiled with the Stage 1 compiler and lowered to a .so with eco-boot-native, as
# test/embed/run-node-addon-tests.sh does; the .so then links the host's libstdc++, like libmax.so.

REPO      ?= $(abspath $(CURDIR)/../..)
ECO_BUILD ?= $(REPO)/build
BOOT      := $(ECO_BUILD)/runtime/src/codegen/eco-boot-native
# index.js otherwise loads guida.js from the `build/` preset's tree, not ECO_BUILD's.
STAGE1    := GUIDA_JS_PATH=$(ECO_BUILD)/compiler/build-xhr/bin/guida.js \
             node --stack-size=500000 $(REPO)/compiler/bin/index.js
MAX_VENV  ?= $(CURDIR)/.venv
MAX_SITE  := $(firstword $(wildcard $(MAX_VENV)/lib/python3*/site-packages))
MAX_LIB   := $(MAX_SITE)/modular/lib
CXX       ?= g++
CXXFLAGS  := -std=c++20 -O2 -Wall -Wextra -I$(REPO)/runtime/include -I$(MAX_SITE)/max/include
B         := $(CURDIR)/build

all: $(B)/spike $(B)/tensor_host $(B)/bytes_host $(B)/max_bridge $(B)/churn_host

check-venv:
	@test -n "$(MAX_SITE)" || { echo "no MAX venv at $(MAX_VENV): run ./setup.sh"; exit 1; }

# An Elm program in project directory $(1), module $(2), as $(B)/$(3).so
define elm_so
	mkdir -p $(B)
	cd $(1) && { ulimit -s unlimited 2>/dev/null || true; } && $(STAGE1) make src/$(2).elm --output=$(B)/$(3).mlir
	$(BOOT) $(B)/$(3).mlir -o $(B)/$(3).so > $(B)/$(3).lower.log 2>&1 || { tail -20 $(B)/$(3).lower.log; exit 1; }
endef

$(B)/spike: capi/spike.cpp | check-venv
	mkdir -p $(B)
	$(CXX) $(CXXFLAGS) $< -L$(MAX_LIB) -lmax -Wl,-rpath,$(MAX_LIB) -o $@

$(B)/tensor_service.so: embed/json/src/TensorService.elm
	$(call elm_so,embed/json,TensorService,tensor_service)

$(B)/tensor_host: embed/json/tensor_host.cpp $(B)/tensor_service.so | check-venv
	$(CXX) $(CXXFLAGS) $< $(B)/tensor_service.so -L$(MAX_LIB) -lmax -lm -Wl,-rpath,$(B):$(MAX_LIB) -o $@

$(B)/tensor_bytes.so: embed/bytes/src/TensorBytes.elm
	$(call elm_so,embed/bytes,TensorBytes,tensor_bytes)

$(B)/bytes_host: embed/bytes/bytes_host.cpp $(B)/tensor_bytes.so | check-venv
	$(CXX) $(CXXFLAGS) $< $(B)/tensor_bytes.so -L$(MAX_LIB) -lmax -lm -Wl,-rpath,$(B):$(MAX_LIB) -o $@

$(B)/mnist.so: $(wildcard mnist/src/*.elm)
	$(call elm_so,mnist,Mnist,mnist)

$(B)/max_bridge: mnist/host/max_bridge.cpp $(B)/mnist.so | check-venv
	$(CXX) $(CXXFLAGS) $< $(B)/mnist.so -L$(MAX_LIB) -lmax -lm -pthread -Wl,-rpath,$(B):$(MAX_LIB) -o $@

$(B)/churn.so: memgrowth/src/Churn.elm
	$(call elm_so,memgrowth,Churn,churn)

$(B)/churn_host: memgrowth/churn_host.cpp $(B)/churn.so
	$(CXX) $(CXXFLAGS) $< $(B)/churn.so -lm -Wl,-rpath,$(B) -o $@

run-capi: $(B)/spike
	cd capi && $(B)/spike models/mlp_rmo.mlir --compile-twice
	cd capi && $(B)/spike models/sym_mlp.mlir --k 64 --n 17

run-json: $(B)/tensor_host
	cd capi && $(B)/tensor_host models/sym_mlp.mlir

run-bytes: $(B)/bytes_host
	cd capi && $(B)/bytes_host models/sym_mlp.mlir

# FORMAT: bytecode (MLIR bytecode written by mnist/src/MlirBc.elm), generic (the same ops as MLIR
# generic text) or text (MAX's custom mo syntax). Graphs land in work/<FORMAT>/graph-<id>.mlir[bc].
FORMAT ?= bytecode
run-mnist: $(B)/max_bridge
	mkdir -p work/$(FORMAT)
	$(B)/max_bridge $(CURDIR)/work/$(FORMAT) '{"dataDir": "$(CURDIR)/mnist/data", "format": "$(FORMAT)"}'

# The bytecode checked with eco's own LLVM (the commit MAX pins): each graph's bytecode and generic
# text, from runs with FORMAT=bytecode and FORMAT=generic, must read back as the same IR.
MLIR_OPT ?= /opt/llvm-mlir/bin/mlir-opt
check-bytecode:
	@for g in 1 2; do \
	  $(MLIR_OPT) --allow-unregistered-dialect --mlir-print-op-generic work/bytecode/graph-$$g.mlirbc > work/graph-$$g.from-bc.mlir && \
	  $(MLIR_OPT) --allow-unregistered-dialect --mlir-print-op-generic work/generic/graph-$$g.mlir > work/graph-$$g.from-text.mlir && \
	  cmp work/graph-$$g.from-bc.mlir work/graph-$$g.from-text.mlir && \
	  echo "graph $$g: bytecode and generic text read back identical ($$(wc -l < work/graph-$$g.from-bc.mlir) lines)" || exit 1; \
	done

MODE ?= hold
run-churn: $(B)/churn_host
	ECO_GC_PHASE_PROFILE=1 $(B)/churn_host '{"mode":"$(MODE)","steps":3000}'

run-mnist-ref:
	$(MAX_VENV)/bin/python -I mnist/ref/numpy_ref.py mnist/data

clean:
	rm -rf $(B) work

.PHONY: all check-venv run-capi run-json run-bytes run-mnist check-bytecode run-churn run-mnist-ref clean
