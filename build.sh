#!/usr/bin/env bash
set -o pipefail

# --- Configuration ---
TG_LOG_FILE="log.txt"
LAST_SHA_FILE=".build_last_sha"
ZIP_NAME="UPDATE-AnyKernel3-gta9.zip"
CONFIG_FILE="out/.config"

# --- Telegram Functions ---
tg_msg() {
    [ -z "$TG_BOT_TOKEN" ] && return
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$1" \
        -d parse_mode="Markdown" > /dev/null
}

tg_start_monitor() {
    [ -z "$TG_BOT_TOKEN" ] && return
    
    # Send initial message
    RES=$(curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="Build initiated." \
        -d parse_mode="Markdown")
        
    TG_LIVE_MSG_ID=$(echo "$RES" | jq -r '.result.message_id')
    
    # Start background loop
    (
        while true; do
            sleep 5
            if [ -f "$TG_LOG_FILE" ]; then
                LOG_TAIL=$(tail -n 10 "$TG_LOG_FILE")
                TIME=$(date +"%H:%M:%S")
                
                # Create clean JSON payload (No Emojis)
                JSON=$(jq -n \
                    --arg cid "$TG_CHAT_ID" \
                    --arg mid "$TG_LIVE_MSG_ID" \
                    --arg txt "Building... [$TIME]
\`\`\`
$LOG_TAIL
\`\`\`" \
                    '{chat_id: $cid, message_id: $mid, text: $txt, parse_mode: "Markdown"}')

                curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/editMessageText" \
                    -H "Content-Type: application/json" \
                    -d "$JSON" > /dev/null
            fi
        done
    ) &
    TG_MONITOR_PID=$!
}

tg_stop_monitor() {
    if [ -n "$TG_MONITOR_PID" ]; then
        kill "$TG_MONITOR_PID" 2>/dev/null
        wait "$TG_MONITOR_PID" 2>/dev/null
    fi
}

tg_upload_log() {
    [ -z "$TG_BOT_TOKEN" ] && return
    tg_msg "Build failed. Uploading log..."
    curl -s -F chat_id="$TG_CHAT_ID" \
         -F document=@"$TG_LOG_FILE" \
         -F caption="Build Log (Failure)" \
         "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
}

# Trap interrupts (Ctrl+C) and exits to ensure monitor is killed
trap 'tg_stop_monitor; echo "Build cancelled."; exit 130' INT

# --- Main Script ---

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

# Start Telegram Monitor
tg_start_monitor

# Configure
make -C $(pwd) O=$(pwd)/out CC=clang LLVM=1 ARCH=arm64 DTC_EXT=$(pwd)/tools/dtc CLANG_TRIPLE=aarch64-linux-gnu- vendor/gta9p_eur_openx_defconfig 2>&1 | tee "$TG_LOG_FILE"

# Run the build
if make -C $(pwd) O=$(pwd)/out CC=clang LLVM=1 ARCH=arm64 DTC_EXT=$(pwd)/tools/dtc CLANG_TRIPLE=aarch64-linux-gnu- -j$(nproc --all) 2>&1 | tee -a "$TG_LOG_FILE"; then
    echo "Build completed successfully."
    tg_stop_monitor # Stop the loop immediately on success
else
    echo "Build failed." >&2
    tg_stop_monitor # Stop the loop
    tg_upload_log   # Upload the error log
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
cd AnyKernel3 && zip -r9 "$ZIP_NAME" * -x .git README.md *placeholder

echo "Done."

# --- Upload Success ---
if [ -n "$TG_BOT_TOKEN" ]; then
    # Changelog Logic
    if [ -f "../$LAST_SHA_FILE" ]; then
        LAST_SHA=$(cat "../$LAST_SHA_FILE")
        # Get log from last build to now
        CHANGELOG=$(git log --pretty=format:"%h: %s" "$LAST_SHA..HEAD")
        [ -z "$CHANGELOG" ] && CHANGELOG="No new commits."
    else
        # First run: just show last 5
        CHANGELOG=$(git log --pretty=format:"%h: %s" -n 5)
    fi

    CAPTION="Build complete: ${ZIP_NAME}

${CHANGELOG}"

    # Upload Zip (Note: We are inside AnyKernel3 folder now)
    curl -s -F chat_id="$TG_CHAT_ID" -F document=@"$ZIP_NAME" -F caption="$CAPTION" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
    
    # Upload Config (Note: path is relative to previous root)
    curl -s -F chat_id="$TG_CHAT_ID" -F document=@"../$CONFIG_FILE" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null

    # Save hash for next time
    git rev-parse HEAD > "../$LAST_SHA_FILE"
fi
