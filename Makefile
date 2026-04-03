.DEFAULT_GOAL := help
.PHONY: build compile run binary clean help ffi

SCHEME = scheme
JERBOA_HOME ?= $(HOME)/mine/jerboa
JERBOA_AWS_HOME ?= $(HOME)/mine/jerboa-aws
CHEZ_LEVELDB_HOME ?= $(HOME)/mine/chez-leveldb
CHEZ_YAML_HOME ?= $(HOME)/mine/chez-yaml
CHEZ_ZLIB_HOME ?= $(HOME)/mine/chez-zlib
CHEZ_HTTPS_HOME ?= $(HOME)/mine/chez-https
CHEZ_SSL_HOME ?= $(HOME)/mine/chez-ssl

LIBDIRS = lib:$(JERBOA_HOME)/lib:$(JERBOA_AWS_HOME)/lib:$(CHEZ_LEVELDB_HOME):$(CHEZ_YAML_HOME):$(CHEZ_ZLIB_HOME)/src:$(CHEZ_HTTPS_HOME)/src:$(CHEZ_SSL_HOME)/src

help:
	@echo "kunabi - CloudTrail Log Analyzer (Jerboa Edition)"
	@echo ""
	@echo "Targets:"
	@echo "  ffi        Build FFI shims (.so files)"
	@echo "  compile    Compile .sls modules to .so"
	@echo "  run        Run kunabi in interpreter mode"
	@echo "  binary     Build standalone static binary"
	@echo "  clean      Remove built artifacts"
	@echo ""
	@echo "Examples:"
	@echo "  make ffi compile && make run ARGS='help'"
	@echo "  make binary"

ffi:
	@echo "=== Building FFI shims ==="
	@if [ -f $(CHEZ_LEVELDB_HOME)/leveldb_shim.c ]; then \
		gcc -shared -fPIC -O2 -o chez_leveldb_shim.so $(CHEZ_LEVELDB_HOME)/leveldb_shim.c -lleveldb; \
	else echo "  SKIP: chez-leveldb (not found at $(CHEZ_LEVELDB_HOME)/leveldb_shim.c)"; fi
	@if [ -f $(CHEZ_ZLIB_HOME)/chez_zlib_shim.c ]; then \
		gcc -shared -fPIC -O2 -o chez_zlib_shim.so $(CHEZ_ZLIB_HOME)/chez_zlib_shim.c -lz; \
	else echo "  SKIP: chez-zlib (not found at $(CHEZ_ZLIB_HOME)/chez_zlib_shim.c)"; fi

compile: ffi
	@echo "=== Compiling kunabi modules ==="
	$(SCHEME) -q --libdirs $(LIBDIRS) --compile-imported-libraries < compile-modules.ss

build: compile

run: compile
	@echo "=== Running kunabi ==="
	@ln -sf $(CHEZ_SSL_HOME)/chez_ssl_shim.so ./chez_ssl_shim.so 2>/dev/null || true
	@ln -sf $(CHEZ_ZLIB_HOME)/chez_zlib_shim.so ./chez_zlib_shim.so 2>/dev/null || true
	CHEZ_LEVELDB_SHIM=$(CHEZ_LEVELDB_HOME)/leveldb_shim.so \
	LD_LIBRARY_PATH=.:$(CHEZ_LEVELDB_HOME):$(CHEZ_YAML_HOME):$(CHEZ_ZLIB_HOME):$(CHEZ_SSL_HOME):$(CHEZ_HTTPS_HOME) \
	$(SCHEME) --libdirs $(LIBDIRS) --script kunabi.ss $(ARGS)

binary: compile
	@echo "=== Building standalone kunabi binary ==="
	JERBOA_DIR=$(JERBOA_HOME)/lib JERBOA_AWS_DIR=$(JERBOA_AWS_HOME)/lib \
	CHEZ_LEVELDB_DIR=$(CHEZ_LEVELDB_HOME) CHEZ_YAML_DIR=$(CHEZ_YAML_HOME)/src \
	CHEZ_ZLIB_DIR=$(CHEZ_ZLIB_HOME)/src CHEZ_HTTPS_DIR=$(CHEZ_HTTPS_HOME)/src CHEZ_SSL_DIR=$(CHEZ_SSL_HOME)/src \
	LD_LIBRARY_PATH=.:$(CHEZ_LEVELDB_HOME):$(CHEZ_YAML_HOME):$(CHEZ_ZLIB_HOME) \
	$(SCHEME) -q --libdirs $(LIBDIRS) < build-kunabi.ss

clean:
	rm -f kunabi
	rm -f lib/kunabi/*.so lib/kunabi/*.wpo
	rm -f *.so *.o *.wpo *.boot
	rm -f kunabi_*.h

# Example: make run ARGS="list users"
