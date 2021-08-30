# Haiku Cross Compiler + Sysroot

This repo contains a script for building a Haiku cross-compiler and accompanying sysroot, where packages can be extracted.

`./build-rootfs.sh` will download the current Haiku and buildtools repos, build the cross-compiler, then the main Haiku
and development packages, and extract all downloaded and built packages into the sysroot.

Additional packages can be extracted with `./package-extract.sh <path-to-package.hpkg>`, which will extract them into the
sysroot for you.

The easiest way to obtain packages is to copy them out of a running Haiku install. Haiku provides the `pkgman` CLI tool
for installing packages. You can install the package containing a specific library with `pkgman install devel:libz`, as a
simple example. This will fetch both the build time and runtime packages, both of which need to be installed. E.g.
- `./package-extract.sh libz-*.hpkg`
- `./package-extract.sh libz_devel-*.hpkg`

Packages can also be downloaded directly at:
- x86_gcc2 hybrid: https://eu.hpkg.haiku-os.org/haikuports/master/x86_gcc2/current/packages/
- x86_64: https://eu.hpkg.haiku-os.org/haikuports/master/x86_64/current/packages/
