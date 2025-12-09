#!/usr/bin/env bash
set -o pipefail
trap 'echo "Build cancelled by user."; exit 130' INT

# --- Telegram Integration ---
TG_LOG_FILE="log.txt"
TG_LAST_SHA_FILE=".build_last_sha"

tg_msg() {
    [ -n "$TG_BOT_TOKEN" ] && curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" -d chat_id="$TG_CHAT_ID" -d text="$1" -d parse_mode="Markdown" > /dev/null
}

tg_monitor() {
    MSG_ID=$1
    while kill -0 "$2" 2>/dev/null; do
        LOG_TAIL=$(tail -n 10 "$TG_LOG_FILE")
        TIME=$(date +"%H:%M:%S")
        # Clean JSON payload, no emojis
        JSON=$(jq -n --arg cid "$TG_CHAT_ID" --arg mid "$MSG_ID" --arg txt "Build in progress... [$TIME]
\`\`\`
$LOG_TAIL
\`\`\`" '{chat_id: $cid, message_id: $mid, text: $txt, parse_mode: "Markdown"}')
        curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/editMessageText" -H "Content-Type: application/json" -d "$JSON" > /dev/null
        sleep 5
    done
}

tg_start() {
    if [ -n "$TG_BOT_TOKEN" ]; then
        RES=$(curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" -d chat_id="$TG_CHAT_ID" -d text="Build initiated." -d parse_mode="Markdown")
        export TG_LIVE_MSG_ID=$(echo "$RES" | jq -r '.result.message_id')
    fi
}

tg_fail() {
    [ -n "$TG_BOT_TOKEN" ] && curl -s -F chat_id="$TG_CHAT_ID" -F document=@"$TG_LOG_FILE" -F caption="Build failed. Log attached." "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
}

# Download Prebuilt Clang (AOSP)
if [ ! -d $(pwd)/toolchain/clang/aosp ]; then
    echo "Downloading Prebuilt Clang from AOSP..."
    mkdir -p $(pwd)/toolchain/clang/aosp
   git clone https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-6573524 $(pwd)/toolchain/clang/aosp
else
    echo "This $(pwd)/toolchain/clang/aosp already exists."
fi
# Exports
export ARCH=arm64
export CROSS_COMPILE=$(pwd)/toolchain/clang/aosp/bin
export CLANG_TOOL_PATH=$(pwd)/toolchain/clang/aosp/bin
export PATH=${CLANG_TOOL_PATH}:${PATH//"${CLANG_TOOL_PATH}:"}
export LD_LIBRARY_PATH=$(pwd)/toolchain/clang/aosp/lib
make -C $(pwd) O=$(pwd)/out CC=clang LLVM=1 ARCH=arm64 DTC_EXT=$(pwd)/tools/dtc CLANG_TRIPLE=aarch64-linux-gnu- vendor/gta9p_eur_openx_defconfig 2>&1 | tee log.txt

tg_start 
( tg_monitor "$TG_LIVE_MSG_ID" $$ ) & TG_MON_PID=$!
# Run the build
if make -C $(pwd) O=$(pwd)/out CC=clang LLVM=1 ARCH=arm64 DTC_EXT=$(pwd)/tools/dtc CLANG_TRIPLE=aarch64-linux-gnu- -j$(nproc --all) 2>&1 | tee -a log.txt; then
kill "$TG_MON_PID" 2>/dev/null
    echo "Build completed successfully."
else
kill "$TG_MON_PID" 2>/dev/null; tg_fail
    echo "Build failed or was cancelled. Exiting." >&2
    exit 1
fi
# Final Build
mkdir -p kernelbuild
echo "Copying Image into kernelbuild..."
cp -nf $(pwd)/out/arch/arm64/boot/Image $(pwd)/kernelbuild
echo "Done copying Image/.gz into kernelbuild."
mkdir -p modulebuild
echo "Copying modules into modulebuild..."
cp -nr $(find out -name '*.ko') $(pwd)/modulebuild
echo "Stripping debug symbols from modules..."
$(pwd)/toolchain/clang/aosp/bin/llvm-strip --strip-debug $(pwd)/modulebuild/*.ko
echo "Done copying modules into modulebuild."
# AnyKernel3 Support
cp -nf $(pwd)/kernelbuild/Image $(pwd)/AnyKernel3
cp -nr $(pwd)/modulebuild/*.ko $(pwd)/AnyKernel3/modules/system/lib/modules
cd AnyKernel3 && zip -r9 boomksu-AnyKernel3-gta9p.zip * -x .git README.md *placeholder
echo "Done."

# --- Upload Logic ---
if [ -n "$TG_BOT_TOKEN" ]; then
    ZIP_NAME="UPDATE-AnyKernel3-gta9.zip"
    CONFIG_FILE="out/.config"
    
    # Changelog Logic
    if [ -f "$TG_LAST_SHA_FILE" ]; then
        LAST_SHA=$(cat "$TG_LAST_SHA_FILE")
        CHANGELOG=$(git log --pretty=format:"%h: %s" "$LAST_SHA..HEAD")
        [ -z "$CHANGELOG" ] && CHANGELOG="No new commits."
    else
        CHANGELOG=$(git log --pretty=format:"%h: %s" -n 5)
    fi

    CAPTION="Build complete: ${ZIP_NAME}

${CHANGELOG}"

    curl -s -F chat_id="$TG_CHAT_ID" -F document=@"AnyKernel3/$ZIP_NAME" -F caption="$CAPTION" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
    curl -s -F chat_id="$TG_CHAT_ID" -F document=@"$CONFIG_FILE" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
    
    git rev-parse HEAD > "$TG_LAST_SHA_FILE"
fi
