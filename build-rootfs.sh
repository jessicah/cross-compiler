#!/usr/bin/env bash

set -e

__InitialDir=$PWD

if [ -z "$__RootfsDir" ] && [ ! -z "$ROOTFS_DIR" ]; then
	__RootfsDir=$ROOTFS_DIR
else
	__RootfsDir="$__InitialDir"
fi

mkdir -p $__RootfsDir
__RootfsDir="$( cd "$__RootfsDir" && pwd )"

JOBS=${MAXJOBS:="$(getconf _NPROCESSORS_ONLN)"}

# For now, assume we're building for x86_64
echo 'Building Haiku sysroot for x86_64'
mkdir -p "$__RootfsDir/tmp"
pushd "$__RootfsDir/tmp"
if [ ! -e "$__RootfsDir/tmp/haiku/.git" ]; then
	git clone --depth=1 https://review.haiku-os.org/haiku
else
	echo "WARN: skipping clone of haiku repo, already exists"
fi

if [ ! -e "$__RootfsDir/tmp/buildtools/.git" ]; then
	git clone --depth=1 https://github.com/haiku/buildtools
else
	echo "WARN: skipping clone of buildtools repo, already exists"
fi

# Fetch some patches that haven't been merged yet
cd "$__RootfsDir/tmp/haiku"
git reset --hard origin/master
## use relative symlinks in _devel package
git fetch origin refs/changes/18/4218/2 && git cherry-pick FETCH_HEAD
## add development build profile (slimmer than nightly)
git fetch origin refs/changes/64/4164/1 && git cherry-pick FETCH_HEAD
## add the patch for providing an explicit sysroot
git am "$__InitialDir/0001-cross_tools-allow-specifying-a-custom-sysroot-path.patch"

# Build jam
echo 'Building jam buildtool'
cd "$__RootfsDir/tmp/buildtools/jam"
make

# Configure cross tools
echo "Building cross tools with $JOBS parallel jobs"
mkdir -p "$__RootfsDir/generated"
cd "$__RootfsDir/generated"
"$__RootfsDir/tmp/haiku/configure" -j"$JOBS" --sysroot "$__RootfsDir" --cross-tools-source "$__RootfsDir/tmp/buildtools" --build-cross-tools x86_64

# Build haiku packages
echo 'Building Haiku packages and package tool'
echo 'HAIKU_BUILD_PROFILE = "development-raw" ;' > UserProfileConfig
"$__RootfsDir/tmp/buildtools/jam/jam0" -j"$JOBS" -q '<build>package' '<repository>Haiku'

# Setup the sysroot
echo 'Extracting packages into sysroot'
mkdir -p "$__RootfsDir/boot/system"
for file in "$__RootfsDir/generated/objects/haiku/x86_64/packaging/packages/"*.hpkg; do
	"$__RootfsDir/generated/objects/linux/x86_64/release/tools/package/package" extract -C "$__RootfsDir/boot/system" "$file"
done
for file in "$__RootfsDir/generated/download/"*.hpkg; do
	"$__RootfsDir/generated/objects/linux/x86_64/release/tools/package/package" extract -C "$__RootfsDir/boot/system" "$file"
done

# Create a script for running `package extract`
cat >"$__RootfsDir/package_extract.sh" <<EOF
#!/usr/bin/env bash

"$__RootfsDir/generated/objects/linux/x86_64/release/tools/package/package" extract -C "$__RootfsDir/boot/system" "\$1"

echo "Extracted \$1 into the Haiku sysroot"
EOF
chmod +x "$__RootfsDir/package_extract.sh"

# And done!
popd
