.DEFAULT_GOAL := help
.PHONY: build compile run binary install clean help ffi

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
	@echo "  install    Install kunabi wrapper script to ~/bin"
	@echo "  clean      Remove built artifacts"
	@echo ""
	@echo "Examples:"
	@echo "  make ffi compile && make run ARGS='help'"
	@echo "  make install && kunabi help"

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

install: compile
	@echo "=== Installing kunabi ==="
	@mkdir -p $(HOME)/bin
	@# Create shim symlinks in project directory
	@ln -sf $(CHEZ_SSL_HOME)/chez_ssl_shim.so $(CURDIR)/chez_ssl_shim.so 2>/dev/null || true
	@ln -sf $(CHEZ_ZLIB_HOME)/chez_zlib_shim.so $(CURDIR)/chez_zlib_shim.so 2>/dev/null || true
	@echo '#!/bin/bash' > $(HOME)/bin/kunabi
	@echo '# kunabi - CloudTrail Log Analyzer (Jerboa Edition)' >> $(HOME)/bin/kunabi
	@echo 'SCRIPT_DIR="$(CURDIR)"' >> $(HOME)/bin/kunabi
	@echo 'JERBOA_HOME="$(JERBOA_HOME)"' >> $(HOME)/bin/kunabi
	@echo 'JERBOA_AWS_HOME="$(JERBOA_AWS_HOME)"' >> $(HOME)/bin/kunabi
	@echo 'CHEZ_LEVELDB_HOME="$(CHEZ_LEVELDB_HOME)"' >> $(HOME)/bin/kunabi
	@echo 'CHEZ_YAML_HOME="$(CHEZ_YAML_HOME)"' >> $(HOME)/bin/kunabi
	@echo 'CHEZ_ZLIB_HOME="$(CHEZ_ZLIB_HOME)"' >> $(HOME)/bin/kunabi
	@echo 'CHEZ_HTTPS_HOME="$(CHEZ_HTTPS_HOME)"' >> $(HOME)/bin/kunabi
	@echo 'CHEZ_SSL_HOME="$(CHEZ_SSL_HOME)"' >> $(HOME)/bin/kunabi
	@echo 'export CHEZ_LEVELDB_SHIM="$$CHEZ_LEVELDB_HOME/leveldb_shim.so"' >> $(HOME)/bin/kunabi
	@echo 'export LD_LIBRARY_PATH="$$CHEZ_SSL_HOME:$$CHEZ_ZLIB_HOME:$$CHEZ_LEVELDB_HOME:$$CHEZ_YAML_HOME:$$CHEZ_HTTPS_HOME:$$SCRIPT_DIR"' >> $(HOME)/bin/kunabi
	@echo 'LIBDIRS="$$SCRIPT_DIR/lib:$$JERBOA_HOME/lib:$$JERBOA_AWS_HOME/lib:$$CHEZ_LEVELDB_HOME:$$CHEZ_YAML_HOME:$$CHEZ_ZLIB_HOME/src:$$CHEZ_HTTPS_HOME/src:$$CHEZ_SSL_HOME/src"' >> $(HOME)/bin/kunabi
	@echo 'cd "$$SCRIPT_DIR" && exec scheme --libdirs "$$LIBDIRS" --script kunabi.ss "$$@"' >> $(HOME)/bin/kunabi
	@chmod +x $(HOME)/bin/kunabi
	@echo "Installed: $(HOME)/bin/kunabi"
	@echo "Make sure $(HOME)/bin is in your PATH"

clean:
	rm -f lib/kunabi/*.so lib/kunabi/*.wpo
	rm -f *.so *.o *.wpo *.boot
	rm -f kunabi_*.h

# Example: make run ARGS="list users"
