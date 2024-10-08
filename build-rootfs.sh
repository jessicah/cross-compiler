#!/usr/bin/env bash

set -e

usage()
{
	echo "Usage: $0 BuildArch [--jobs <N>] [--rootfsdir <directory>] [--haiku-repo <uri>] [--bt-repo <uri>] [-- {extra args}]"
	echo "BuildArch can be: x86, x86_64, x86h, x86_gcc2h"
	echo "--rootfsdir dir   - defaults to the current dir, where to"
	echo "                    put cross-compiler and Haiku sysroot."
	echo "--jobs N          - restrict to N jobs, defaults to MAXCPUS."
	echo "--haiku-repo uri  - alternate uri to clone Haiku repo from."
	echo "--bt-repo uri     - alternate uri to clone buildtools from."
	echo "Any additional arguments after -- will be passed directly to"
	echo "Haiku's configure script."
	exit 1
}

__InitialDir=$PWD
__RootfsDir="$__InitialDir"

case $1 in
	x86|x86_64)
		__BuildArch=$1
		;;
	x86h)
		__BuildArch=x86
		__BuildSecondaryArch=x86_gcc2
		;;
	x86_gcc2h)
		__BuildArch=x86_gcc2
		__BuildSecondaryArch=x86
		;;
	*)
		usage
		;;
esac

shift

while :; do
	if [ $# -le 0 ]; then
		break
	fi

	case $1 in
		--rootfsdir|-rootfsdir)
			shift
			__RootfsDir=$1
			;;
		--jobs|-jobs)
			shift
			MAXJOBS=$1
			;;
		--haiku-repo|-haiku-repo)
			shift
			__HaikuRepo=$1
			;;
		--bt-repo|-bt-repo)
			shift
			__BuildToolsRepo=$1
			;;
		--)
			shift
			break
			;;
		*)
			echo "Unknown option: $1"
			usage
	esac

	shift
done

if [ $# -gt 0 ]; then
	__ExtraArgs="$@"
fi


if [ -z "$__RootfsDir" ] && [ ! -z "$ROOTFS_DIR" ]; then
	__RootfsDir=$ROOTFS_DIR
fi

echo "Using $__RootfsDir..."

mkdir -p $__RootfsDir
__RootfsDir="$( cd "$__RootfsDir" && pwd )"

if [ -z "$__HaikuRepo" ]; then
	__HaikuRepo="https://github.com/haiku/haiku"
fi

if [ -z "$__BuildToolsRepo" ]; then
	__BuildToolsRepo="https://github.com/haiku/buildtools"
fi

JOBS=${MAXJOBS:="$(getconf _NPROCESSORS_ONLN)"}

if [ -z "$__BuildSecondaryArch" ]; then
	echo "Building Haiku sysroot for $__BuildArch"
else
	echo "Building Haiku sysroot for $__BuildArch/$__BuildSecondaryArch hybrid"
fi
mkdir -p "$__RootfsDir/tmp"
if [ ! -e "$__RootfsDir/tmp/haiku/.git" ]; then
	cd "$__RootfsDir/tmp"
	git clone "$__HaikuRepo"
	cd haiku && git remote add review https://review.haiku-os.org/haiku && git fetch --tags review
else
	echo "WARN: skipping clone of haiku repo, already exists"
	cd "$__RootfsDir/tmp/haiku" && git fetch review
fi

if [ ! -e "$__RootfsDir/tmp/buildtools/.git" ]; then
	cd "$__RootfsDir/tmp"
	git clone --depth=1 "$__BuildToolsRepo"
else
	echo "WARN: skipping clone of buildtools repo, already exists"
fi

# Fetch some patches that haven't been merged yet
cd "$__RootfsDir/tmp/haiku"
git reset --hard review/master
git am "$__InitialDir/0003-build-add-an-optional-UserProfileConfig.patch"

# Build jam
echo 'Building jam buildtool'
cd "$__RootfsDir/tmp/buildtools/jam"
make
./jam0 -sBINDIR="$__RootfsDir/bin" install

# Configure cross tools
echo "Building cross tools with $JOBS parallel jobs"
mkdir -p "$__RootfsDir/generated"
cd "$__RootfsDir/generated"
if [ -z "$__BuildSecondaryArch" ]; then
	"$__RootfsDir/tmp/haiku/configure" -j"$JOBS" --sysroot "$__RootfsDir" --cross-tools-source "$__RootfsDir/tmp/buildtools" --build-cross-tools $__BuildArch $__ExtraArgs
else
	"$__RootfsDir/tmp/haiku/configure" -j"$JOBS" --sysroot "$__RootfsDir" --cross-tools-source "$__RootfsDir/tmp/buildtools" --build-cross-tools $__BuildArch --build-cross-tools $__BuildSecondaryArch $__ExtraArgs
fi

# Build haiku packages
echo 'Building Haiku packages and package tool'
echo 'HAIKU_BUILD_PROFILE = "nightly-raw" ;' > UserProfileConfig
"$__RootfsDir/bin/jam" -j"$JOBS" -q '<build>package' '<repository>Haiku'

# Find the package command
__PackageCommand=`echo $__RootfsDir/generated/objects/*/*/release/tools/package/package`

# Setup the sysroot
echo 'Extracting packages into sysroot'
mkdir -p "$__RootfsDir/boot/system"
for file in "$__RootfsDir/generated/objects/haiku/$__BuildArch/packaging/repositories/Haiku/packages/"*.hpkg; do
	echo "Extracting $file..."
	"$__PackageCommand" extract -C "$__RootfsDir/boot/system" "$file"
done
for file in "$__RootfsDir/generated/download/"*.hpkg; do
	echo "Extracting $file..."
	"$__PackageCommand" extract -C "$__RootfsDir/boot/system" "$file"
done

# Create a script for running `package extract`
cat >"$__RootfsDir/package_extract.sh" <<EOF
#!/usr/bin/env bash

"$__PackageCommand" extract -C "$__RootfsDir/boot/system" "\$1"

echo "Extracted \$1 into the Haiku sysroot"
EOF
chmod +x "$__RootfsDir/package_extract.sh"

# Create a script for fetching a list of packages
cat >"$__RootfsDir/fetch_packages.sh" <<EOF
#!/usr/bin/env bash

found_packages=()
missing_packages=()

for package in "\$@" ; do
	json='{"name":"'"\$package"'","repositorySourceCode":"haikuports_$__BuildArch","versionType":"LATEST","naturalLanguageCode":"en"}'
	echo "Getting download URL for \$package..."
	url=\$(wget -qO- --post-data="\$json" --header='Content-Type:application/json' 'https://depot.haiku-os.org/__api/v2/pkg/get-pkg' | jq -r '.result.versions[].hpkgDownloadURL' 2>/dev/null)
	if [ \$? -eq 0 ]; then
		echo "Downloading \$package at \$url..."
		wget -q "\$url"
		if [ \$? -eq 0 ]; then
			echo "Extracting \$package..."
			"$__RootfsDir/package_extract.sh" \$package*.hpkg
			rm \$package*.hpkg
			found_packages+=("\$package")
			continue
		fi

		echo "Unable to download \$package"
	else
		echo "Unable to locate \$package for downloading"
	fi
	missing_packages+=("\$package")
done

echo ""

if [ \${#missing_packages[@]} -ne 0 ]; then
	echo "Missing Packages:"
	for package in \${missing_packages[@]}; do
		echo " - \$package"
	done
	echo ""
fi

if [ \${#found_packages[@]} -ne 0 ]; then
	echo "Installed Packages:"
	for package in \${found_packages[@]}; do
		echo " - \$package"
	done
else
	echo "NO packages installed"
fi
EOF
chmod +x "$__RootfsDir/fetch_packages.sh"

# Clean up
rm -rf "$__RootfsDir/tmp/" "$__RootfsDir/generated/objects/haiku/" "$__RootfsDir/generated/objects/common"
rm -rf "$__RootfsDir/generated/attributes/" "$__RootfsDir/generated/download/" "$__RootfsDir/generated/build_packages/"

# And done!
if [ -z "$__BuildSecondaryArch" ]; then
	echo "Completed build of Haiku cross-compiler for $__BuildArch"
else
	echo "Completed build of Haiku cross-compiler for $__BuildArch/$__BuildSecondaryArch hybrid"
fi

echo ""
echo "Your cross-compiler is available in $__RootfsDir/generated/cross-tools-{ARCH}/bin/,"
echo "and the sysroot extracted into $__RootfsDir/boot/system."
echo ""
echo "You can also use $__RootfsDir/package_extract.sh to extract packages into the sysroot,"
echo "or use $__RootfsDir/fetch_packages.sh with a space separated list of package names to"
echo "automatically download and install into the sysroot (requires \`jq\` to be installed)."
if [ -z "$__BuildSecondaryArch" ]; then
	echo "Download packages from https://eu.hpkg.haiku-os.org/haikuports/master/$__BuildArch/current/packages."
else
	echo "Download primary arch packages from https://eu.hpkg.haiku-os.org/haikuports/master/$__BuildArch/current/packages,"
	echo "and secondary arch packages from https://eu.hpkg.haiku-os.org/haikuports/master/$__BuildSecondaryArch/current/packages."
fi
echo ""
