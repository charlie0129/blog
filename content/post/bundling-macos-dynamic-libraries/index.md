---
title: Bundling macOS Dynamic Libraries
description: This post describes how to bundle macOS dynamic libraries, with portable QEMU build as an example.
slug: bundling-macos-dynamic-libraries
date: 2026-06-08 12:25:00+0800
categories:
    - macos
    - dynamic-libraries
    - building
tags:
    - macos
    - dynamic libraries
    - qemu
    - build
---

I recently tried to build QEMU on macOS and make the result portable enough that it could still run after uninstalling the Homebrew packages used during the build, or I can move the whole QEMU directory to another machine. I don't want the Homebrew build because it installs too many dependencies on the system, and I want a more self-contained bundle, not a system-wide installation.

The short version: **fully static linking on macOS is not really the right target**. macOS binaries still dynamically link against Apple system libraries such as `libSystem`. But for tools like QEMU, what I really wanted was not a “pure static binary”; I wanted a self-contained directory like this:

```text
_qemu-11.0.1/
├── bin/
│   ├── qemu-img
│   ├── qemu-system-x86_64
│   └── ...
└── lib/
    ├── libglib-2.0.0.dylib
    ├── libgobject-2.0.0.dylib
    ├── libintl.8.dylib
    ├── libpcre2-8.0.dylib
    └── ...
```

The binaries in `bin/` should load their non-system dependencies from `../lib` (note that it's relative, not absolute, so it will work even if the whole directory is moved), instead of from `/opt/homebrew`.

This post records the process, using QEMU as the example.

## The original problem

I built QEMU roughly like this:

```sh
# You should refer to https://wiki.qemu.org/Hosts/Mac for the latest build instructions. This is just an example.
brew install libffi gettext glib pkg-config zstd # may not be the exact set of dependencies you need

./configure --prefix="$HOME/bin/_qemu-11.0.1"
make -j"$(sysctl -n hw.ncpu)"
make install
```

The build worked. But after uninstalling some Homebrew dependencies, running `qemu-img` failed:

```text
dyld[82783]: Library not loaded: /opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib
  Referenced from: /Users/charlie/bin/_qemu-11.0.1/bin/qemu-img
  Reason: tried: '/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib' (no such file)
zsh: abort      qemu-img
```

This means the installed QEMU binary still contains an absolute dependency path:

```text
/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib
```

We can confirm that with:

```sh
otool -L "$PREFIX/bin/qemu-img"
```

Example output:

```text
qemu-img:
    /opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib (compatibility version 8801.0.0, current version 8801.0.0)
    /opt/homebrew/opt/zstd/lib/libzstd.1.dylib (compatibility version 1.0.0, current version 1.5.7)
    /usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
    ...
```

The `/usr/lib` and `/System/Library` entries are fine. They are macOS system libraries. The `/opt/homebrew/...` entries are the ones that make the binary depend on my local Homebrew installation.

## Why not just build QEMU fully static?

On Linux, the natural thought is “just build a static binary”.

On macOS, that is not usually how things work. macOS does not support the same style of fully static userland binary that Linux users often expect. You can try to statically link some third-party libraries, but the final program will still dynamically link to Apple system libraries.

So the practical goal is:

Bundle third-party `.dylib` dependencies next to the program, and rewrite Mach-O load commands so the binary loads those local copies.

This is similar in spirit to what many `.app` bundles do, but here I wanted a plain CLI directory layout.

## The tools involved

macOS Mach-O binaries can be inspected and patched with these tools:

```sh
otool -L <file>
install_name_tool -change <old> <new> <file>
install_name_tool -id <new-id> <dylib>
install_name_tool -add_rpath <rpath> <file>
```

`otool -L` shows dynamic library load commands.

For example:

```sh
otool -L "$PREFIX/bin/qemu-img"
```

might show:

```text
qemu-img:
    /opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib (compatibility version 8801.0.0, current version 8801.0.0)
    /opt/homebrew/opt/zstd/lib/libzstd.1.dylib (compatibility version 1.0.0, current version 1.5.7)
    /usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
    ...
```

Those can be rewritten with:

```sh
install_name_tool -change \
  /opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib \
  '@executable_path/../lib/libglib-2.0.0.dylib' \
  "$PREFIX/bin/qemu-img"
```

`@executable_path` means “the directory containing the executable being launched”.

So it will try to find `libglib-2.0.0.dylib` in `../lib/` relative to the executable, no longer looking in `/opt/homebrew`.

## First attempt: patch direct dependencies only

My first attempt was simple:

```sh
otool -L "$PREFIX"/bin/* \
  | grep /opt/homebrew \
  | sort \
  | uniq \
  | awk '{print $1}'
```

This found direct Homebrew dependencies used by QEMU binaries, such as:

```text
/opt/homebrew/opt/glib/lib/libgio-2.0.0.dylib
/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib
/opt/homebrew/opt/glib/lib/libgmodule-2.0.0.dylib
/opt/homebrew/opt/glib/lib/libgobject-2.0.0.dylib
/opt/homebrew/opt/zstd/lib/libzstd.1.dylib
```

Then I copied those libraries into `$PREFIX/lib` and patched the binaries.

This fixed some errors, but not all of them.

Running `qemu-img` then failed with a different error:

```text
dyld[97126]: Library not loaded: /opt/homebrew/opt/gettext/lib/libintl.8.dylib
  Referenced from: /Users/charlie/bin/_qemu-11.0.1/lib/libglib-2.0.0.dylib
```

So I realized that it is not enough to patch only the binaries. The copied `.dylib` files have their own dependencies too.

In this case:

```text
qemu-img
  -> libglib-2.0.0.dylib
       -> libintl.8.dylib
```

`libintl.8.dylib` was not directly referenced by `qemu-img`. It was a transitive dependency of `libglib`.

## The correct model

The dependency graph looks like this:

```text
bin/qemu-img
  -> /opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib
  -> /opt/homebrew/opt/zstd/lib/libzstd.1.dylib

lib/libglib-2.0.0.dylib
  -> /opt/homebrew/opt/gettext/lib/libintl.8.dylib
  -> /opt/homebrew/opt/pcre2/lib/libpcre2-8.0.dylib
```

So the bundling process must be recursive:

1. Scan Mach-O files in `bin/`.
2. Find its `/opt/homebrew` dependencies.
3. Copy those `.dylib` files into `lib/`.
4. Patch the binaries to refer to the bundled copies (`../lib`).
5. Scan the copied `.dylib` files.
6. Copy and patch their dependencies too.
7. Repeat until no `/opt/homebrew` dependencies remain.

## Which paths should be used?

For executables in `bin/`, I use:

```text
@executable_path/../lib/libfoo.dylib
```

For dylibs inside `lib/`, I use:

```text
@loader_path/libfoo.dylib
```

- `@executable_path` is relative to the main executable being launched.
- `@loader_path` is relative to the Mach-O file that is doing the loading. For dependencies between dylibs, this is what we want:

  ```text
  lib/libglib-2.0.0.dylib
    -> @loader_path/libintl.8.dylib
  ```

Since both files are in the same `lib/` directory, this resolves correctly.

## The final bundling script

I ended up writing a small Python script called `macho-bundle-deps`. You can find it here: https://github.com/charlie0129/dotfiles/blob/f15791054e517f6b5afc892312f1db73f331d475/bin/darwin/macho-bundle-deps. This is a permanent link to a specific commit, so you may want to check the latest version in the repository.

Usage:

```sh
PREFIX="$HOME/bin/_qemu-11.0.1"

macho-bundle-deps \
  --lib-dir "$PREFIX/lib" \
  --prefix /opt/homebrew \
  "$PREFIX"/bin
```

Or, from inside the QEMU prefix:

```sh
cd "$HOME/bin/_qemu-11.0.1"

macho-bundle-deps --lib-dir lib bin
```

The script does the following:

- finds Mach-O files from the input paths
- scans their dependencies with `otool -L`
- copies matching dependencies into `--lib-dir`
- patches executable dependencies to `@executable_path/../lib/...`
- patches bundled dylib dependencies to `@loader_path/...`
- patches copied dylib IDs with `install_name_tool -id`
- recursively processes newly copied dylibs
- reports an error if matching absolute dependency paths remain

## Verifying the result

After running the bundler, I verify that no Homebrew paths remain:

```sh
otool -L "$PREFIX"/bin/* "$PREFIX"/lib/*.dylib | grep /opt/homebrew
```

Now I can uninstall the dependencies from Homebrew, and the bundled QEMU still works:

```sh
brew uninstall libffi gettext glib
qemu-img --help
```

## Notes and limitations

This is not the same as producing a fully static binary.

The result still depends on macOS system libraries, which is normal:

```text
/usr/lib/libSystem.B.dylib
/System/Library/Frameworks/...
```

It also does not magically make a binary portable across all macOS versions or CPU architectures. A binary built on Apple Silicon is still an arm64 Mach-O binary unless built otherwise.

This approach is mainly useful for making a local CLI tool directory self-contained with respect to Homebrew dependencies.

## Why copying symlinks should be avoided

Homebrew often has dylib symlinks like:

```text
libintl.dylib -> libintl.8.dylib
```

When bundling, prefer copying the symlink target, not the symlink itself.

In shell, that means:

```sh
cp -L source.dylib "$PREFIX/lib/"
```

In Python, `shutil.copy2(..., follow_symlinks=True)` does the same thing.

This avoids ending up with a bundled symlink pointing to a non-existent file.

## Final layout

After bundling, the QEMU directory looks like this:

```text
_qemu-11.0.1/
├── bin/
│   ├── qemu-img
│   ├── qemu-io
│   ├── qemu-nbd
│   ├── qemu-system-aarch64
│   ├── qemu-system-x86_64
│   └── ...
└── lib/
    ├── libffi.8.dylib
    ├── libgio-2.0.0.dylib
    ├── libglib-2.0.0.dylib
    ├── libgmodule-2.0.0.dylib
    ├── libgobject-2.0.0.dylib
    ├── libintl.8.dylib
    ├── libpcre2-8.0.dylib
    └── libzstd.1.dylib
```

Now `qemu-img` no longer cares whether Homebrew’s `glib`, `gettext`, `pcre2`, or `zstd` packages are installed.

## Conclusion

The main lesson is that macOS dependency bundling is graph traversal, not a one-shot patch.

Patching only the top-level binaries is not enough. You also need to patch the dylibs that you copied, and then patch the dylibs that those dylibs depend on.

The final strategy is:

```text
scan -> copy -> patch -> scan copied dylibs -> repeat
```

For executables:

```text
/opt/homebrew/.../libfoo.dylib
  -> @executable_path/../lib/libfoo.dylib
```

For bundled dylibs:

```text
/opt/homebrew/.../libbar.dylib
  -> @loader_path/libbar.dylib
```

And for the dylib’s own install name:

```text
/opt/homebrew/.../libfoo.dylib
  -> @loader_path/libfoo.dylib
```
