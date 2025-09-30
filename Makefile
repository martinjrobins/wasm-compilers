PYTHON := /usr/bin/env python3
DIR := $(shell pwd)
SYSROOT := ${DIR}/build/sysroot
CLANG_VERSION := $(shell /usr/bin/env bash ./llvm_version_major.sh llvm-project)

OUTPUT := ${DIR}/build/output

LLVM_HOST := ${DIR}/build/llvm-host

WASM_CC := ${LLVM_HOST}/bin/clang
WASM_CXX := ${LLVM_HOST}/bin/clang++
WASM_NM := ${LLVM_HOST}/bin/llvm-nm
WASM_AR := ${LLVM_HOST}/bin/llvm-ar
WASM_CFLAGS := -ffile-prefix-map=${DIR}=/ -matomics -mbulk-memory -mmutable-globals
WASM_CXXFLAGS := -ffile-prefix-map=${DIR}=/ -matomics -mbulk-memory -mmutable-globals \
								 -stdlib=libstdc++ -I ${SYSROOT}/include/c++/15.0.0/wasm32-wasip1/ \
								 -I ${SYSROOT}/include/c++/15.0.0/
WASM_LDFLAGS := -Wl,-z -Wl,stack-size=10485760 \
								-Wl,--shared-memory -Wl,--export-memory -Wl,--import-memory \
								-Wl,--max-memory=4294967296 \
								-Wl,--initial-memory=41943040 \
								-L${SYSROOT}/lib/
MAKE := make

RT_DIR := wasm32-unknown-wasip1-threads


all: ${OUTPUT}.DONE test

build:
	mkdir -p build

build/llvm-host.BUILT: llvm-project | build
	rsync -a --delete llvm-project/ build/llvm-host-src
	cmake -S build/llvm-host-src/llvm -B build/llvm-host-build \
		-DCMAKE_INSTALL_PREFIX="${DIR}/build/llvm-host" -DDEFAULT_SYSROOT=${SYSROOT} \
		-DCMAKE_BUILD_TYPE=Release \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasip1-threads \
		-DLLVM_ENABLE_PROJECTS="clang;lld"
	$(MAKE) -C build/llvm-host-build install
	touch $@

build/wasi-libc.BUILT: wasi-libc build/llvm-host.BUILT | build
	rsync -a --delete wasi-libc/ build/wasi-libc
	sed -i 's/#define DEFAULT_STACK_SIZE 131072/#define DEFAULT_STACK_SIZE 10485760/' \
		build/wasi-libc/libc-top-half/musl/src/internal/pthread_impl.h
	$(MAKE) -C build/wasi-libc THREAD_MODEL=posix \
		CC=${WASM_CC} AR=$(WASM_AR) NM=${WASM_NM} EXTRA_CFLAGS="${WASI_CFLAGS} -O2 -DNDEBUG" \
		INSTALL_DIR=${SYSROOT} install
	touch $@

build/llvm.SRC: llvm-project | build
	rsync -a --delete llvm-project/ build/llvm-src
	touch $@

build/compiler-rt-host.BUILT: build/llvm.SRC build/wasi-libc.BUILT
	mkdir -p build/compiler-rt-build-host
	cmake -B build/compiler-rt-build-host -S build/llvm-src/compiler-rt/lib/builtins \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_CFLAGS}" \
		-DCOMPILER_RT_BAREMETAL_BUILD=On \
		-DCOMPILER_RT_INCLUDE_TESTS=OFF \
		-DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=On \
		-DCOMPILER_RT_OS_DIR=${RT_DIR} \
		-DCMAKE_INSTALL_PREFIX=${LLVM_HOST}/lib/clang/$(CLANG_VERSION)/
	$(MAKE) -C build/compiler-rt-build-host install
	mv ${LLVM_HOST}/lib/clang/$(CLANG_VERSION)/lib/${RT_DIR}/libclang_rt.builtins-wasm32.a \
		${LLVM_HOST}/lib/clang/$(CLANG_VERSION)/lib/${RT_DIR}/libclang_rt.builtins.a
	touch $@ 

build/compiler-rt.BUILT: build/llvm.SRC build/compiler-rt-host.BUILT
	mkdir -p build/compiler-rt-build
	cmake -B build/compiler-rt-build -S build/llvm-src/compiler-rt/lib/builtins \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_CFLAGS}" \
		-DCOMPILER_RT_BAREMETAL_BUILD=On \
		-DCOMPILER_RT_INCLUDE_TESTS=OFF \
		-DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=On \
		-DCOMPILER_RT_OS_DIR=${RT_DIR} \
		-DCMAKE_INSTALL_PREFIX=${SYSROOT}/lib/clang/$(CLANG_VERSION)/
	$(MAKE) -C build/compiler-rt-build install
	mv ${SYSROOT}/lib/clang/$(CLANG_VERSION)/lib/${RT_DIR}/libclang_rt.builtins-wasm32.a \
		${SYSROOT}/lib/clang/$(CLANG_VERSION)/lib/${RT_DIR}/libclang_rt.builtins.a
	touch $@ 

LIBSTDCXX_FLAGS=-fsized-deallocation -Wno-unknown-warning-option -Wno-vla-cxx-extension \
		-Wno-unused-function -Wno-instantiation-after-specialization \
		-Wno-missing-braces -Wno-unused-variable -Wno-string-plus-int \
		-Wno-unused-parameter -fno-exceptions -Wno-init-priority-reserved \
		-Wno-invalid-constexpr

build/libstdcxx.BUILT: build/compiler-rt.BUILT
	rsync -a --delete gcc/ build/gcc
	mkdir -p build/gcc-build
	cd build/gcc-build && \
		PATH=${LLVM_HOST}/bin:$$PATH LDFLAGS="${WASM_LDFLAGS}" \
		CXXFLAGS="${LIBSTDCXX_FLAGS} ${WASM_CXXFLAGS}" \
		../gcc/libstdc++-v3/configure --prefix=${SYSROOT} \
		--host wasm32-wasip1 --target wasm32-wasip1 --build=$(shell $(CC) -dumpmachine) \
		CC=${WASM_CC} CXX=${WASM_CXX} AR=${WASM_AR} NM=${WASM_NM} \
		--enable-libstdcxx-threads --enable-shared=off -disable-libstdcxx-dual-abi \
		--enable-libstdcxx-filesystem-ts --enable-libstdcxx-time=yes
	cd build/gcc-build && PATH=${LLVM_HOST}/bin:$$PATH $(MAKE) \
		CFLAGS_FOR_TARGET="${WASM_CFLAGS} -fsized-deallocation" \
		CXXFLAGS_FOR_TARGET="${WASM_CXXFLAGS}" install
	touch "$@"

build/llvm.BUILT: build/llvm.SRC build/libstdcxx.BUILT
	cmake -B build/llvm-build -S build/llvm-src/llvm \
		-DCMAKE_BUILD_TYPE=MinSizeRel \
		-DCMAKE_SYSROOT=$(SYSROOT) -DCMAKE_INSTALL_PREFIX="${SYSROOT}" -DDEFAULT_SYSROOT=/ \
		-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
		-DCMAKE_C_FLAGS="-I${DIR} ${WASM_CFLAGS}" \
		-DCMAKE_CXX_FLAGS="-I${DIR} ${WASM_CXXFLAGS} -fno-exceptions" \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly \
		-DLLVM_INCLUDE_BENCHMARKS=OFF \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly \
		-DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasip1-threads \
		-DLLVM_INCLUDE_TESTS=OFF -DCLANG_PLUGIN_SUPPORT=OFF \
		-DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_PIC=OFF \
		-DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_ENABLE_PLUGINS=OFF \
		-DCMAKE_EXE_LINKER_FLAGS="${WASM_LDFLAGS}"
	$(MAKE) -C build/llvm-build install
	touch "$@"

build/enzyme-host.BUILT: Enzyme/enzyme build/llvm.BUILT
	rsync -a --delete Enzyme/enzyme/ build/enzyme-host-src
	mkdir -p build/enzyme-host-build
	cmake -B build/enzyme-host-build -S build/enzyme-host-src \
		-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="${DIR}/build/enzyme-host" -DDEFAULT_SYSROOT=${SYSROOT} \
	-DLLVM_DIR="${DIR}/build/llvm-host"
	$(MAKE) -C build/enzyme-host-build install
	touch "$@"


build/enzyme.BUILT: Enzyme/enzyme build/llvm.BUILT build/enzyme-host.BUILT
	rsync -a --delete Enzyme/enzyme/ build/enzyme-src
	mkdir -p build/enzyme-build
	cmake -B build/enzyme-build -S build/enzyme-src \
		-DCMAKE_BUILD_TYPE=MinSizeRel \
	-DCMAKE_SYSROOT=$(SYSROOT) -DCMAKE_INSTALL_PREFIX="${SYSROOT}" -DDEFAULT_SYSROOT=/ \
	-DWASM_PREFIX=${LLVM_HOST} -DCMAKE_TOOLCHAIN_FILE=${DIR}/cmake/toolchain.cmake \
	-DCMAKE_C_FLAGS="-I${DIR} ${WASM_CFLAGS}" \
	-DCMAKE_CXX_FLAGS="-I${DIR} ${WASM_CXXFLAGS} -fno-exceptions" \
	-DCMAKE_EXE_LINKER_FLAGS="${WASM_LDFLAGS}" \
	-DEnzyme_TABLEGEN_EXE="${DIR}/build/enzyme-host-build/tools/enzyme-tblgen/enzyme-tblgen" \
	-DENZYME_CONFIGURED_WITH_PRESETS=OFF \
	-DENZYME_STATIC_LIB=ON \
	-DENZYME_ENABLE_PLUGINS=OFF \
	-DENZYME_BC_LOADER=OFF \
	-DLLVM_DIR=${SYSROOT} \
	-DENZYME_CLANG=OFF
	$(MAKE) -C build/enzyme-build install
	touch "$@"

${OUTPUT}.DONE: build/enzyme.BUILT

clean:
	rm -rf build/

.PHONY: all test clean

.NOTINTERMEDIATE:
