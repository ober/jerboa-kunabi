#!/bin/bash
# build-kunabi-musl.sh — Build kunabi as a fully static binary using musl libc
#
# Prerequisites:
#   - musl-gcc installed (apt install musl-tools)
#   - Chez Scheme built with: ./configure --threads --static CC=musl-gcc
#     and installed to ~/chez-musl (or set JERBOA_MUSL_CHEZ_PREFIX)
#   - Jerboa and Gherkin libraries compiled
set -euo pipefail

JERBOA_DIR="${JERBOA_DIR:-$HOME/mine/jerboa}"
JERBOA_LIB="${JERBOA_DIR}/lib"
GHERKIN_DIR="${GHERKIN_DIR:-$HOME/mine/gherkin/src}"
JERBOA_AWS_DIR="${JERBOA_AWS_DIR:-$HOME/mine/jerboa-aws/lib}"
CHEZ_LEVELDB_DIR="${CHEZ_LEVELDB_DIR:-$HOME/mine/chez-leveldb}"
CHEZ_YAML_DIR="${CHEZ_YAML_DIR:-$HOME/mine/chez-yaml}"
CHEZ_ZLIB_DIR="${CHEZ_ZLIB_DIR:-$HOME/mine/chez-zlib/src}"
CHEZ_HTTPS_DIR="${CHEZ_HTTPS_DIR:-$HOME/mine/chez-https/src}"
CHEZ_SSL_DIR="${CHEZ_SSL_DIR:-$HOME/mine/chez-ssl/src}"

echo "==================================="
echo "Building kunabi with musl libc (static)"
echo "==================================="
echo ""
echo "Jerboa:      $JERBOA_LIB"
echo "Gherkin:     $GHERKIN_DIR"
echo "jerboa-aws:  $JERBOA_AWS_DIR"
echo "chez-leveldb: $CHEZ_LEVELDB_DIR"
echo ""

# Check musl availability
if ! command -v musl-gcc &>/dev/null; then
	echo "ERROR: musl-gcc not found"
	echo "Install: sudo apt install musl-tools"
	exit 1
fi

# Use jerboa's musl module to validate and build
echo "[1/2] Validating musl toolchain via jerboa..."
LIBDIRS="lib:${JERBOA_LIB}:${GHERKIN_DIR}:${JERBOA_AWS_DIR}:${CHEZ_LEVELDB_DIR}:${CHEZ_YAML_DIR}:${CHEZ_ZLIB_DIR}:${CHEZ_HTTPS_DIR}:${CHEZ_SSL_DIR}"
scheme -q --libdirs "$LIBDIRS" <<'VALIDATE'
(import (chezscheme) (jerboa build musl))
(let ([result (validate-musl-setup)])
  (printf "  ~a: ~a~n" (car result) (cdr result))
  (unless (eq? (car result) 'ok)
    (exit 1)))
VALIDATE

echo ""
echo "[2/2] Running musl build..."
LD_LIBRARY_PATH=. scheme -q --libdirs "$LIBDIRS" <build-kunabi-musl.ss

# Verify
if [ -f "kunabi-musl" ]; then
	echo ""
	echo "==================================="
	echo "kunabi-musl built successfully!"
	echo "==================================="
	ls -lh kunabi-musl
	echo ""
	file kunabi-musl
	echo ""
	ldd kunabi-musl 2>&1 || echo "  (Fully static - no dependencies)"
	echo ""
	echo "Test: ./kunabi-musl help"
else
	echo "ERROR: kunabi-musl not created"
	exit 1
fi
