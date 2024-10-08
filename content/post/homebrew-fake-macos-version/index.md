---
title: Fake macOS Version Detected by Homebrew
description: Fake macOS Version Detected by Homebrew so that you can install Bottles, i.e. precompiled binaries, on unsupported macOS versions.
slug: homebrew-fake-macos-version
date: 2024-10-08 22:08:00+0800
categories:
    - homebrew
    - macos
tags:
    - homebrew
    - macos
---

## Background

One particular issue that I encountered when I tried to install some software using Homebrew on my Mac is that Homebrew deprecates support for older macOS versions just like Apple do. Once a macOS version is deprecated, Homebrew will not provide bottles (precompiled binaries) for that version. This means that you have to compile the software from source, which is extremely time-consuming and sometimes error-prone. Imagine installing `shell-check` will require to build `ghc` from source, which takes hours, and then use `ghc` to build `shell-check` from source. This is not a good experience.

## Solution

### Pin homebrew/core to an older version

One way to work around this issue is to use a older version of the `homebrew/core` tap, such that the bottles are still available for the macOS version you are using because they are built when your macOS version is supported. The downside is that you will be using outdated software. If this is not an issue for you then congratulations. You can achieve this by running the following command:

```console
$ brew tap homebrew/core
$ cd $(brew --repo homebrew/core)
$ git reset --hard <commit-hash>
```

Make sure you disable the auto-update of Homebrew so that it does not update the `homebrew/core` tap to the latest version. You can do this by running the following command:

```console
$ echo 'export HOMEBREW_NO_AUTO_UPDATE=1' >> ~/.zshrc
```

### Fake macOS version

Another way is to fake the macOS version that Homebrew detects. This way, Homebrew will provide bottles for the macOS version you are faking. Most software will work and you will be using the latest software. However, this may not work for all software as some software may have dependencies that are not available for the macOS version you are faking. You can achieve this by running the following command:

```console
$ export HOMEBREW_FAKE_MACOS=13.0 # Choose a macOS version that is supported by Homebrew and close to your macOS version
$ brew install xxx
```

## Explanation

Homebrew actually has an private undocumented API that allows you to fake the macOS version. https://github.com/Homebrew/brew/blob/a3d8f4e0e4a22da9990d59cca70bec1e7be726cf/Library/Homebrew/os/mac.rb#L41

```ruby
# This can be compared to numerics, strings, or symbols
# using the standard Ruby Comparable methods.
#
# @api internal
sig { returns(MacOSVersion) }
def self.full_version
    @full_version ||= if (fake_macos = ENV.fetch("HOMEBREW_FAKE_MACOS", nil)) # for Portable Ruby building
        MacOSVersion.new(fake_macos)
    else
        MacOSVersion.new(VERSION)
    end
end
```

## Example

I have macOS Monterey (12.0) running, which is just deprecated by Homebrew. I want to install `batt` which is not available as a bottle for macOS Monterey.

If I run `brew install batt`, I will get the following error:

```console
$ brew install batt
Warning: You are using macOS 12.
We (and Apple) do not provide support for this old version.
It is expected behaviour that some formulae will fail to build in this old version.
It is expected behaviour that Homebrew will be buggy and slow.
Do not create any issues about this on Homebrew's GitHub repositories.
Do not create any issues even if you think this message is unrelated.
Any opened issues will be immediately closed without response.
Do not ask for help from Homebrew or its maintainers on social media.
You may ask for help in Homebrew's discussions but are unlikely to receive a response.
Try to figure out the problem yourself and submit a fix as a pull request.
We will review it but may or may not accept it.
```

It's Oct 8, 2024 and the latest macOS version is macOS Sequoia (15.0). So the last 3 supported macOS versions are:

- macOS Sequoia (15.0)
- macOS Sonoma (14.0)
- macOS Ventura (13.0)

You can confirm that by checking out `batt`'s formula:

```console
$ brew edit batt
...
sha256 cellar: :any_skip_relocation, arm64_sequoia: "61bd7790a82f2269b9a0ce1585c57564d03be4e4ac89b8f0d8843c0073a688e6"
sha256 cellar: :any_skip_relocation, arm64_sonoma:  "198bd7bb9a808f0a9e4cb1a31b7e9c2a72d690ba1d07ebddf78b6d0ce0b6dd03"
sha256 cellar: :any_skip_relocation, arm64_ventura: "6eff598159b263327b8b562ab32f5e5e7157c20f25cbecfa08b48eda794c4c43"
...
```

Showing only the bottles for macOS Sequoia (15.0), macOS Sonoma (14.0), and macOS Ventura (13.0) are available.

Sadly my macOS version (Monterey 12.0) is not in the list, but macOS Ventura (13.0) is the closest to macOS Monterey (12.0). So I can fake the macOS version to macOS Ventura (13.0) by running the following command:

```console
$ export HOMEBREW_FAKE_MACOS=13.0
$ brew config
...
macOS: 13.0-arm64 # YES! I'm now faking macOS Ventura (13.0)
...
$ brew install batt
==> Downloading https://ghcr.io/v2/homebrew/core/batt/manifests/0.3.1
Already downloaded: /Users/charlie/Library/Caches/Homebrew/downloads/86da7d77f0bacb44475e0280eef162148e3b51df8ea44ff9bc16a5a7bba6d39f--batt-0.3.1.bottle_manifest.json
==> Fetching batt
==> Downloading https://ghcr.io/v2/homebrew/core/batt/blobs/sha256:6eff598159b263327b8b562ab32f5e5e7157c20f25cbecfa08b48eda794c4c43
Already downloaded: /Users/charlie/Library/Caches/Homebrew/downloads/24fc002de2ee11096a544dd84ff1033262a5cb627c2b824c915a552bb6a588dd--batt--0.3.1.arm64_ventura.bottle.tar.gz
```

As you can see, Homebrew is downloading the bottle for macOS Ventura (13.0) successfully! (Of course, the log is showing that I have already downloaded earlier, but you get the idea.)

`batt` itself does not rely on any APIs that are not available in my current macOS version, so it works perfectly fine.
