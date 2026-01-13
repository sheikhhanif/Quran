# Quick Start: Enable HarfBuzz

## Prerequisites
```bash
pip3 install meson ninja
```

## Build HarfBuzz
```bash
cd android
./build_harfbuzz.sh arm64
```

This will:
- Clone HarfBuzz source
- Build for Android arm64
- Install to `android/harfbuzz-build/arm64/install`

## Rebuild App
```bash
cd ..
flutter clean
flutter build apk --debug
```

CMakeLists.txt will automatically detect and link HarfBuzz!

## Verify
Check build logs for: `*** HarfBuzz ENABLED successfully! ***`
