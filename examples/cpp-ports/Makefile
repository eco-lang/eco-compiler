# Builds the Elm program as a shared library and links the C++ host against it.
#
#     make
#     ./upcase < Makefile
#
# The embedding headers are found next to the `eco` on the PATH, in <prefix>/include (override with
# ECO_INCLUDE=...).

ECO ?= eco
CXX ?= c++
ECO_INCLUDE ?= $(dir $(realpath $(shell command -v $(ECO))))../include

upcase: host.cpp build/libupcase.so
	$(CXX) -std=c++20 -O2 -Wall -Wextra -I$(ECO_INCLUDE) host.cpp \
		-Lbuild -l:libupcase.so -lm -Wl,-rpath,'$$ORIGIN/build' -o $@

build/libupcase.so: src/Upcase.elm elm.json
	$(ECO) make src/Upcase.elm --output=$@

clean:
	rm -rf build upcase

.PHONY: clean
