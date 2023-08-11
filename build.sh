#!/bin/bash

set -eu -o pipefail
KERNEL_REPOSITORY=git://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/lunar
CODENAME=$(lsb_release -c | cut -d ":" -f 2 | xargs)
REPO_PATH=$(pwd)
WORKING_PATH=/root/work
KERNEL_PATH="${WORKING_PATH}/linux-kernel"

get_next_version () {
  echo "$PKGREL"
}

### Clean up
rm -rfv ./*.deb

mkdir "${WORKING_PATH}" && cd "${WORKING_PATH}"
cp -rf "${REPO_PATH}"/{patches,templates} "${WORKING_PATH}"
rm -rf "${KERNEL_PATH}"

### Dependencies
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y build-essential fakeroot libncurses-dev bison flex libssl-dev libelf-dev \
  openssl dkms libudev-dev libpci-dev libiberty-dev autoconf wget xz-utils git default-jdk \
  libcap-dev bc rsync cpio dh-modaliases debhelper kernel-wedge curl gawk dwarves llvm zstd \
  wget rustc-1.62 rust-1.62-src rustfmt-1.62 bindgen-0.56 llvm clang

echo "DBG: Gettings info about latest tag"
REMOTE_LATEST_TAG=$(git ls-remote --tags --sort=-creatordate ${KERNEL_REPOSITORY} 2>&1 | sed 's/.*refs\/tags\///' | sed 's/\^{}//')
echo "DBG: Latest tag is ${REMOTE_LATEST_TAG}"

### get Kernel
git clone --depth 1 --single-branch --branch "${REMOTE_LATEST_TAG}" "${KERNEL_REPOSITORY}" "${KERNEL_PATH}"
cd "${KERNEL_PATH}" || exit
LATEST_TAG=$(git tag --sort=-creatordate | head -1)
git checkout "$LATEST_TAG"

KERNEL_VERSION="${LATEST_TAG}-generic"

IFS='-' read -r UBUNTU_NAME KERNEL_REL UBUNTU_REL <<< "$LATEST_TAG"

### Debug commands
echo "$UBUNTU_NAME KERNEL_VERSION=$KERNEL_VERSION"
echo "${WORKING_PATH}"
echo "Current path: ${REPO_PATH}"
echo "CPU threads: $(nproc --all)"
grep 'model name' /proc/cpuinfo | uniq

#### Create patch file with custom drivers
echo >&2 "===]> Info: Creating patch file... "
KERNEL_VERSION="${KERNEL_VERSION}" WORKING_PATH="${WORKING_PATH}" "${REPO_PATH}/patch_driver.sh"

#### Apply patches
cd "${KERNEL_PATH}" || exit

echo >&2 "===]> Info: Applying patches... "
[ ! -d "${WORKING_PATH}/patches" ] && {
  echo 'Patches directory not found!'
  exit 1
}


while IFS= read -r file; do
  echo "==> Adding $file"
  patch -p1 <"$file"
done < <(find "${WORKING_PATH}/patches" -type f -name "*.patch" | sort)

chmod a+x "${KERNEL_PATH}"/debian/rules
chmod a+x "${KERNEL_PATH}"/debian/scripts/*
chmod a+x "${KERNEL_PATH}"/debian/scripts/misc/*

cd "${KERNEL_PATH}"
echo >&2 "===]> Info: Config kernel ... "
wget https://raw.githubusercontent.com/mahboobkarimian/T2-Ubuntu-Kernel/Ubuntu/.config
make olddefconfig
# Build Deb packages
echo >&2 "===]> Info: fakeroot clean... "
sed -i "s/${KERNEL_REL}-${UBUNTU_REL}/${KERNEL_REL}-${UBUNTU_REL}+t2/g" debian.master/changelog
#LANG=C fakeroot debian/rules clean
# Disable debug info
./scripts/config --undefine GDB_SCRIPTS
./scripts/config --undefine DEBUG_INFO
./scripts/config --undefine DEBUG_INFO_SPLIT
./scripts/config --undefine DEBUG_INFO_REDUCED
./scripts/config --undefine DEBUG_INFO_COMPRESSED
./scripts/config --set-val  DEBUG_INFO_NONE       y
./scripts/config --set-val  DEBUG_INFO_DWARF5     n

make olddefconfig

# Enable T2 drivers
./scripts/config --module CONFIG_HID_APPLE_IBRIDGE
./scripts/config --module CONFIG_HID_APPLE_TOUCHBAR
./scripts/config --module CONFIG_HID_APPLE_MAGIC_BACKLIGHT
echo >&2 "===]> Info: Bulding src... "
#make ARCH=x86 mrproper
#LANG=C fakeroot debian/rules binary-headers binary-generic binary-perarch
# Get rid of the dirty tag
#echo "" >"${KERNEL_PATH}"/.scmversion

# Build Deb packages
make -j "$(getconf _NPROCESSORS_ONLN)" deb-pkg LOCALVERSION=-t2-"${CODENAME}" KDEB_PKGVERSION="${KERNEL_REL}-${UBUNTU_REL}"

#### Copy artifacts to shared volume
echo >&2 "===]> Info: Copying debs and calculating SHA256 ... "
#cp -rfv ../*.deb "${REPO_PATH}/"
#cp -rfv "${KERNEL_PATH}/.config" "${REPO_PATH}/kernel_config_${KERNEL_VERSION}"
cp -rfv "${KERNEL_PATH}/debian/build/build-generic/.config" "/tmp/artifacts/kernel_config_${KERNEL_VERSION}"
cp -rfv ../*.deb /tmp/artifacts/
sha256sum ../*.deb >/tmp/artifacts/sha256
