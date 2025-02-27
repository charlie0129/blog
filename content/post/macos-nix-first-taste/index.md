---
title: macOS Nix First Taste
description: Long gone Homebrew. My first experience with Nix on macOS.
slug: macos-nix-first-taste
date: 2024-06-27 15:13:00+0800
categories:
    - package-manager
    - macos
tags:
    - macos
    - nix
---

## Note

Note that this blog currently acts as a reference for me. It is not a comprehensive guide on why and how to use Nix on macOS.

I chose nix because I am tired of Homebrew's slowness and NOT PROVIDING BOTTLES (BINARY) FOR OLD MACOS VERSIONS.

## Install 

I am not using the official installer because it cannot survive macOS updates. Instead, I am using the Determinate System's Nix Installer.

```bash
ARCH=$(uname -m | sed 's/arm64/aarch64/')
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
curl -L -o nix-installer https://github.com/DeterminateSystems/nix-installer/releases/latest/download/nix-installer-$ARCH-$OS
chmod +x nix-installer
# Optionally, move nix-installer to your PATH
# sudo install nix-installer /usr/local/bin
./nix-installer install --explain
```

## Pin Nixpkgs

I don't want to download a tarball and extract it every now and then. I know you can set tarball-ttl to a higher value, but I don't want to do that either. Just pin nixpkgs.

```bash
nix registry pin nixpkgs
```

If you are like me in China, you may want to use a mirror. 

```bash
echo "substituters = https://mirrors.sjtug.sjtu.edu.cn/nix-channels/store/ https://cache.nixos.org/" | sudo tee -a /etc/nix/nix.conf
```

## Using

I wrote some scripts just to make my life easier. 

- [nix-install](https://github.com/charlie0129/dotfiles/blob/master/bin/common/nix-install)
- [nix-list](htts://github.com/charlie0129/dotfiles/blob/master/bin/common/nix-list)
- [nix-search](htts://github.com/charlie0129/dotfiles/blob/master/bin/common/nix-search)
- [nix-uninstall](htts://github.com/charlie0129/dotfiles/blob/master/bin/common/nix-uninstall)

## Later Steps

There is [nix-darwin](https://github.com/LnL7/nix-darwin) to make declarative configuration easier. I don't have time to try it yet but I will definitely give it a try when I have time.
