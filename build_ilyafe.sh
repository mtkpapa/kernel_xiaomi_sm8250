#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.

# Ensure the script exits on error
set -e

TOOLCHAIN_PATH=$HOME/zyclang21/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE=$1

if [ -z "$1" ]; then
    echo "Error: No argument provided, please specific a target device." 
    echo "If you need KernelSU, please add [ksu] as the second arg."
    echo "Examples:"
    echo "Build for lmi(K30 Pro/POCO F2 Pro) without KernelSU:"
    echo "    bash build.sh lmi"
    echo "Build for umi(Mi10) with KernelSU:"
    echo "    bash build.sh umi ksu"
    exit 1
fi



if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

if ! command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
    echo "[aarch64-linux-gnu-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v arm-linux-gnueabi-ld >/dev/null 2>&1; then
    echo "[arm-linux-gnueabi-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "[clang] does not exist, please check your environment."
    exit 1
fi


# Enable ccache for speed up compiling 
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"
echo "CCACHE_DIR: [$CCACHE_DIR]"


MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip HOSTCC=clang HOSTCXX=clang++ LD=ld.lld LLVM=1 LLVM_IAS=1"


if [ "$1" == "j1" ]; then
    make $MAKE_ARGS -j1
    exit
fi

if [ "$1" == "continue" ]; then
    make $MAKE_ARGS -j$(nproc)
    exit
fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Avaliable defconfigs, please choose one target from below down:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi


# Check clang is existing.
echo "[clang --version]:"
clang --version



KSU_ZIP_STR=NoKernelSU
if [ "$2" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=KernelSU-Next-SUSFS
else
    KSU_ENABLE=0
fi


echo "TARGET_DEVICE: $TARGET_DEVICE"

if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    curl -LSs "https://raw.githubusercontent.com/mtkpapa/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -s next-susfs
else
    echo "KSU is disabled"
fi


echo "Cleaning..."

rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/liyafe1997/AnyKernel3)"
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# Add date to local version
local_version_str="-perf"
local_version_date_str="-FliKernel-$(date +%Y%m%d)"

# ------------- Building for AOSP -------------

echo "Building for AOSP......"
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

sed -i "s/${local_version_str}/${local_version_date_str}/g" out/.config

if [ $KSU_ENABLE -eq 1 ]; then
    scripts/config --file out/.config \
    -e KSU \
    -e KSU_SUSFS_HAS_MAGIC_MOUNT \
    -d KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -d KSU_SUSFS_SUS_OVERLAYFS \
    -e KSU_SUSFS_TRY_UMOUNT \
    -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -d KSU_SUSFS_OPEN_REDIRECT \
    -d KSU_SUSFS_SUS_SU 
else
    scripts/config --file out/.config -d KSU
fi

make $MAKE_ARGS -j$(nproc)


if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. AOSP Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems AOSP build failed."
    exit 1
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

rm -rf anykernel/kernels/

mkdir -p anykernel/kernels/

cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

cd anykernel 

ZIP_FILENAME=FliKernel_AOSP_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S').zip
KOUT_PATH="/mnt/d/users/juan/kernels/${TARGET_DEVICE}/"

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME $KOUT_PATH

cd ..


echo "Build for AOSP finished."

# ------------- End of Building for AOSP -------------
#  If you don't need AOSP you can comment out the above block [Building for AOSP]

# sed -i "s/${local_version_date_str}/${local_version_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

# ------------- End of Building for MIUI -------------
#  If you don't need MIUI you can comment out the above block [Building for MIUI]

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"

rm -rf out/
rm -rf KernelSU-Next/
rm -rf anykernel/
