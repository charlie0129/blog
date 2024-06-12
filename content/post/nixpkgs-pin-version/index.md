---
title: Pin Nixpkgs Version
description: Do not auto-update Nixpkgs
slug: nixpkgs-pin-version
date: 2024-06-12 09:11:00+0800
categories:
    - nix
tags:
    - nix
---

## Background

I am not an auto-update fan. I don't want to be blocked by some stupid auto-update process and have to wait for it to finish, especially when I am in a hurry to get something done. So I always disable auto-update features and prefer to update things manually.

I used Homebrew on macOS before, with auto-update disabled, and I was happy with it. I switched to Nix because I wanted to have a more reproducible environment. But Nix also auto-updates Nixpkgs by default, which I don't like. So I decided to pin the Nixpkgs version to avoid auto-updates.

## Pin Nixpkgs Version

### Add a custom channel with a specific commit

First, you need to remove the current `nixpkgs` channel, if you have one:

```
nix-channel --remove nixpkgs
```

Now, add a new channel with a specific commit or tag. For example, you can find available tags from the [NixOS/nixpkgs on GitHub](https://github.com/NixOS/nixpkgs/tags). I chose `24.05` for this example. Replace `24.05` with the tag you want to use:

```
nix-channel --add https://github.com/NixOS/nixpkgs/archive/refs/tags/24.05.tar.gz nixpkgs
```

### Update the Channels to Use the New Commit

After adding the custom channel, you need to update your channel list:

```
nix-channel --update
```

### Install Packages from the Pinned nixpkgs

You can now install packages from the pinned `nixpkgs`:

```
nix profile install nixpkgs#your-package-name
```

## Conclusion

Now, you can avoid auto-updates and have more control over your environment. I am happy with this setup, and I hope you find it useful too.
