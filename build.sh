#!/bin/sh
# 수집기를 build/focus-collector 로 컴파일한다. (Xcode 없이 Command Line Tools의 swiftc만 필요)
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 collector/main.swift -o build/focus-collector
echo "빌드 완료: $(pwd)/build/focus-collector"
