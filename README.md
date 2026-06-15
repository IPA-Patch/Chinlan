# IPA-Patch/Common

Shared C / Objective-C runtime linked into every IPA-Patch tweak.

This repo holds the small set of headers and implementations that every
consumer tweak (`KiouKifExporter`, `KiouEditor`, `KiouUSIProxy`, …) wants
verbatim:

- `il2cpp.h` — read-only helpers for poking at IL2CPP objects:
  `ptrLooksValid`, `readI32`, `readU8`, `readPtr`, `readRepeatedField`,
  `readArrayElem`, `il2cppStringToNSString`. Header-only (`static inline`)
  so no linker plumbing is needed. **Deliberately read-only** — write
  helpers belong in each tweak's own `Internal.h`.
- `hookengine.h` — `MSHookFunction` <-> `DobbyHook` shim selected at
  compile time via `IPA_JAILED`. Lets `Hook_*.m` stay untouched between
  the rootless-jailbreak build (`libsubstrate`) and the
  sideload-injected build (`libdobby.a` statically linked).
- `logging.h` / `logging.m` — `file_log` + `logging_init`. Multiplexes
  every log line to NSLog, `os_log` (subsystem-scoped), and an
  append-only file inside the app sandbox. `IPA_LOG_TO_DOCUMENTS=1` at
  build time routes the file destination to `<sandbox>/Documents/` so
  Files.app can read it on a non-jailbroken device.

Pure runtime code. No Python tooling, no build scripts — the
[IPA-Patch/Shared](https://github.com/IPA-Patch/Shared) repo holds those.

## Using this repo

Consumer projects add it as a git submodule. The conventional location is
inside the consumer's `Sources/`:

```sh
git submodule add https://github.com/IPA-Patch/Common.git Sources/Common
```

Then point the build at it. For a Theos tweak:

```makefile
TWEAK_FILES   += Sources/Common/logging.m
TWEAK_CFLAGS  += -ISources/Common
```

Each `.m` then includes the headers by their plain name:

```c
#import "il2cpp.h"
#import "hookengine.h"
#import "logging.h"
```

## Build-time flags

The headers and implementation react to these `-D...=1` macros:

| Macro                  | Effect                                                                                  |
| ---------------------- | --------------------------------------------------------------------------------------- |
| `IPA_JAILED`           | `hookengine.h` uses Dobby (statically linked) instead of `libsubstrate`.                |
| `IPA_LOG_TO_DOCUMENTS` | `logging.m` writes its file log to `<sandbox>/Documents/<tag>.log` instead of `tmp/`.   |

The consumer's Makefile flips these from its own build switches —
typically `make JAILED=1` sets `-DIPA_JAILED=1`, and the
statically-patched / sideload-injected flavor adds `-DIPA_LOG_TO_DOCUMENTS=1`.

## License

MIT — see [LICENSE](LICENSE).
