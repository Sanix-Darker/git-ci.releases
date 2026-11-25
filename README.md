# GCI releases

Public release artifacts for GCI: private CI/CD on a machine you own. One Go binary and one SQLite file.

This repository contains:

- compiled GCI binaries (Linux and macOS, amd64 and arm64, stripped)
- SHA-256 checksum manifests
- release notes
- the installer

It does not contain the product source code.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Sanix-Darker/git-ci.releases/main/install.sh -o install.sh
sh install.sh
```

The installer downloads the latest release, checks it against `checksums.txt`, installs `gci`, and runs `gci up` (systemd on Linux, launchd on macOS). Pass `--no-up` to install the binary only, or `--version vX.Y.Z` for a given release.

You can also download an archive from the [latest release](https://github.com/Sanix-Darker/git-ci.releases/releases/latest) and check its SHA-256 against `checksums.txt` yourself.

Agent Skills for GCI: [Sanix-Darker/git-ci-skills](https://github.com/Sanix-Darker/git-ci-skills).
