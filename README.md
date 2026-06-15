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
- `binpatch.h` / `binpatch.m` — generic runtime helpers for the
  "statically-patched `__TEXT` + `__DATA` hook-slot table" distribution
  shape (the only viable iOS 18 sideload hooking shape; CSM kills
  runtime inline rewrites). Two routines:
  - `ipa_binpatch_find_image(name_substring)` walks `_dyld_image_count()`
    and returns the matching image's `mach_header` VA (call from a 1–2 s
    retry loop until non-zero).
  - `ipa_binpatch_resolve_orig(imageBase, siteRVA, cavePayloadSize)`
    decodes the `B <cave>` instruction the patcher wrote at the site
    and returns the in-cave orig-trampoline VA so hook bodies can chain
    back. Assumes the cave's last 8 bytes are
    `<displaced prologue insn> + B <site+4>` — read `binpatch.h` for
    the full cave-layout contract and a wiring example you can paste
    into a new consumer.

  Each consumer still owns the slot-table definition itself
  (`void *g_<your>_hook_slot[N];` in `__DATA,__bss`), its
  `KIOU_SLOT_*`-style enum, and the per-hook `publish_*()` helpers —
  Common owns only the parts that look identical across every consumer.

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
# Consumers that ship a statically-patched-IPA build also add:
TWEAK_FILES   += Sources/Common/binpatch.m
TWEAK_CFLAGS  += -ISources/Common
```

Each `.m` then includes the headers by their plain name:

```c
#import "il2cpp.h"
#import "hookengine.h"
#import "logging.h"
#import "binpatch.h"   // only if you ship a statically-patched IPA
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
