#!/usr/bin/env bash
# Builds the native kernels into build/ (Linux / macOS).
# Windows: cmake -S native -B native/out && cmake --build native/out --config Release
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

CXX="${CXX:-c++}"
case "$(uname -s)" in
  Darwin) OUT=build/libroute_kernels.dylib; SHARED=(-dynamiclib) ;;
  *)      OUT=build/libroute_kernels.so;    SHARED=(-shared -fPIC) ;;
esac

# -ffp-contract=off keeps results bit-identical to the Dart implementation.
"$CXX" -std=c++17 -O2 -ffp-contract=off -fvisibility=hidden "${SHARED[@]}" \
  native/route_kernels.cpp -o "$OUT"
echo "Built $OUT"
