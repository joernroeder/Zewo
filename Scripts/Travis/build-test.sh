#!/usr/bin/env bash

set -e
set -o pipefail

swift build
swift build -c release
swift test

if [[ "$TRAVIS_OS_NAME" == "osx" ]]; then
    swift package generate-xcodeproj
    xcodebuild -project Zewo.xcodeproj -scheme Zewo -sdk macosx10.12 -destination arch=x86_64 -configuration Debug -enableCodeCoverage YES test | xcpretty
fi
