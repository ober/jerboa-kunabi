.DEFAULT_GOAL := help
.PHONY: build compile run binary install clean help ffi docker

SCHEME = scheme
JERBOA_HOME ?= $(HOME)/mine/jerboa
JERBOA_AWS_HOME ?= $(HOME)/mine/jerboa-aws
CHEZ_LEVELDB_HOME ?= $(HOME)/mine/chez-leveldb
CHEZ_YAML_HOME ?= $(HOME)/mine/chez-yaml
CHEZ_ZLIB_HOME ?= $(HOME)/mine/chez-zlib
CHEZ_HTTPS_HOME ?= $(HOME)/mine/chez-https
CHEZ_SSL_HOME ?= $(HOME)/mine/chez-ssl
GHERKIN_HOME ?= $(HOME)/mine/gherkin

LIBDIRS = lib:$(JERBOA_HOME)/lib:$(GHERKIN_HOME)/src:$(JERBOA_AWS_HOME)/lib:$(CHEZ_LEVELDB_HOME):$(CHEZ_YAML_HOME):$(CHEZ_ZLIB_HOME)/src:$(CHEZ_HTTPS_HOME)/src:$(CHEZ_SSL_HOME)/src

help:
	@echo "kunabi - CloudTrail Log Analyzer (Jerboa Edition)"
	@echo ""
	@echo "Build (Docker - recommended for deployment):"
	@echo "  make docker            Build dynamically linked binary in Docker"
	@echo "  make docker-musl       Build fully static musl binary in Docker"
	@echo ""
	@echo "Build (local - requires all dependencies):"
	@echo "  make ffi               Build FFI shims (.so files)"
	@echo "  make compile           Compile .sls modules to .so"
	@echo "  make binary            Build standalone binary"
	@echo ""
	@echo "Other:"
	@echo "  make run               Run kunabi in interpreter mode"
	@echo "  make install           Install kunabi wrapper script to ~/bin"
	@echo "  make clean             Remove built artifacts"
	@echo ""
	@echo "Examples:"
	@echo "  make docker && docker run --rm kunabi-builder help"
	@echo "  make binary && ./kunabi help"

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
	CHEZ_LEVELDB_DIR=$(CHEZ_LEVELDB_HOME) CHEZ_YAML_DIR=$(CHEZ_YAML_HOME) \
	CHEZ_ZLIB_DIR=$(CHEZ_ZLIB_HOME)/src CHEZ_HTTPS_DIR=$(CHEZ_HTTPS_HOME)/src CHEZ_SSL_DIR=$(CHEZ_SSL_HOME)/src \
	LD_LIBRARY_PATH=.:$(CHEZ_LEVELDB_HOME):$(CHEZ_YAML_HOME):$(CHEZ_ZLIB_HOME):$(CHEZ_SSL_HOME) \
	$(SCHEME) -q --libdirs $(LIBDIRS) < build-kunabi.ss

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

# ─── Docker Build ────────────────────────────────────────────────────────────

docker:
	@echo "=== Building kunabi in Docker ==="
	docker build --build-arg CACHE_BUST=$$(date +%s) -t kunabi-builder .
	@echo "=== Docker build complete ==="
	@echo ""
	@echo "Run: docker run --rm kunabi-builder help"
	@echo "Or extract binary: docker cp \$$(docker create kunabi-builder):/usr/local/bin/kunabi ./"

docker-musl:
	@echo "=== Building static kunabi binary (musl/Alpine) ==="
	docker build -f Dockerfile.musl --build-arg CACHE_BUST=$$(date +%s) -t kunabi-musl-builder .
	@echo "=== Extracting binary ==="
	@id=$$(docker create kunabi-musl-builder) && \
		docker cp $$id:/kunabi ./kunabi-musl && \
		docker rm $$id > /dev/null
	@echo ""
	@ls -lh kunabi-musl
	@file kunabi-musl
	@echo ""
	@echo "Test: ./kunabi-musl help"
