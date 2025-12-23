#!/usr/bin/env bash
set -o pipefail

# --- Configuration ---
ROOT_DIR=$(pwd)
TG_LOG_FILE="$ROOT_DIR/log.txt"
LAST_SHA_FILE="$ROOT_DIR/.build_last_sha"
CONFIG_FILE="$ROOT_DIR/out/.config"

# [FIX] Get Git SHA for unique filenames
GIT_SHA=$(git rev-parse --short HEAD)
ZIP_NAME="boomksu-AnyKernel3-gta9p-${GIT_SHA}.zip"

# [FIX] Mark the start time to check for stale images later
touch .build_start

# [FIX] Create .scmversion to prevent "-dirty" suffix mismatch
touch .scmversion

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
        -d text="Build initiated. SHA: \`$GIT_SHA\`" \
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
if [ ! -d "$ROOT_DIR/toolchain/clang/aosp" ]; then
    echo "Downloading Prebuilt Clang from AOSP..."
    mkdir -p "$ROOT_DIR/toolchain/clang/aosp"
   git clone https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-6573524 "$ROOT_DIR/toolchain/clang/aosp"
else
    echo "This $ROOT_DIR/toolchain/clang/aosp already exists."
fi

# Exports
export ARCH=arm64
export CROSS_COMPILE="$ROOT_DIR/toolchain/clang/aosp/bin"
export CLANG_TOOL_PATH="$ROOT_DIR/toolchain/clang/aosp/bin"
export PATH=${CLANG_TOOL_PATH}:${PATH//"${CLANG_TOOL_PATH}:"}
export LD_LIBRARY_PATH="$ROOT_DIR/toolchain/clang/aosp/lib"

# Start Telegram Monitor
tg_start_monitor

# Configure
make -C "$ROOT_DIR" O="$ROOT_DIR/out" CC=clang LLVM=1 ARCH=arm64 DTC_EXT="$ROOT_DIR/tools/dtc" CLANG_TRIPLE=aarch64-linux-gnu- vendor/gta9p_eur_openx_defconfig 2>&1 | tee "$TG_LOG_FILE"

# Run the build
if make -C "$ROOT_DIR" O="$ROOT_DIR/out" CC=clang LLVM=1 ARCH=arm64 DTC_EXT="$ROOT_DIR/tools/dtc" CLANG_TRIPLE=aarch64-linux-gnu- -j$(nproc --all) 2>&1 | tee -a "$TG_LOG_FILE"; then
    echo "Build completed successfully."
    tg_stop_monitor # Stop the loop immediately on success
else
    echo "Build failed." >&2
    tg_stop_monitor # Stop the loop
    tg_upload_log   # Upload the error log
    exit 1
fi

# --- [FIX] Verify Image Freshness ---
IMAGE_PATH="$ROOT_DIR/out/arch/arm64/boot/Image"

if [ ! -f "$IMAGE_PATH" ]; then
    echo "CRITICAL ERROR: Image not found at $IMAGE_PATH" >&2
    exit 1
fi

# Check if the Image file is OLDER than the start of this script
if [ "$IMAGE_PATH" -ot .build_start ]; then
    echo "--------------------------------------------------------"
    echo "WARNING: The Kernel Image was NOT updated!"
    echo "It is older than the script start time."
    echo "This means 'make' thought nothing changed and didn't rebuild."
    echo "To fix: Run 'rm -rf out/' to force a clean build."
    echo "--------------------------------------------------------"
    tg_msg "Build Warning: Image was not updated (Stale)."
    exit 1
fi
echo "Verified: Image was freshly built."

# --- [FIX] Verify Modules Freshness ---
# Find the newest module in the output directory
NEWEST_KO=$(find out -name "*.ko" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -f2- -d" ")

if [ -z "$NEWEST_KO" ]; then
    echo "WARNING: No modules (*.ko) found in out/ directory!"
elif [ "$NEWEST_KO" -ot .build_start ]; then
    echo "--------------------------------------------------------"
    echo "WARNING: Modules were NOT updated!"
    echo "The newest module ($NEWEST_KO) is older than script start."
    echo "This means 'make' thought modules didn't need recompiling."
    echo "--------------------------------------------------------"
    # We don't exit here because sometimes you only change the kernel core (Image),
    # but it's good to know.
else
    echo "Verified: Modules were freshly built."
fi

# --- DTB Compilation Step ---
echo "Compiling DTB manually..."
"$ROOT_DIR/tools/dtc" -I dts -O dtb -o "$ROOT_DIR/dtb.img" "$ROOT_DIR/arch/arm64/boot/dts/vendor/qcom/blair.dts"

if [ ! -f "$ROOT_DIR/dtb.img" ]; then
    echo "Error: dtb.img failed to compile!"
    exit 1
fi
echo "DTB compiled successfully."

# --- Final Build & Packaging ---

# 1. CLEAN STAGING DIRS
echo "Cleaning staging directories..."
rm -rf "$ROOT_DIR/kernelbuild"
rm -rf "$ROOT_DIR/modulebuild"

mkdir -p "$ROOT_DIR/kernelbuild"
mkdir -p "$ROOT_DIR/modulebuild"

# 2. COPY IMAGE
echo "Copying Image into kernelbuild..."
cp -f "$IMAGE_PATH" "$ROOT_DIR/kernelbuild"
echo "Done copying Image."

# 3. COPY MODULES
echo "Copying modules into modulebuild..."
cp -rf $(find out -name '*.ko') "$ROOT_DIR/modulebuild"

echo "Stripping debug symbols from modules..."
"$ROOT_DIR/toolchain/clang/aosp/bin/llvm-strip" --strip-debug "$ROOT_DIR/modulebuild/"*.ko
echo "Done copying modules."

# --- AnyKernel3 Support ---

# 4. CLEAN ANYKERNEL TARGETS
echo "Cleaning AnyKernel3 modules and image..."
rm -rf "$ROOT_DIR/AnyKernel3/modules/system/lib/modules/"*.ko
rm -f "$ROOT_DIR/AnyKernel3/Image"
rm -f "$ROOT_DIR/AnyKernel3/dtb"
# Remove old zips to prevent clutter
rm -f "$ROOT_DIR/AnyKernel3/"*.zip

echo "Copying new files to AnyKernel3..."
cp -f "$ROOT_DIR/kernelbuild/Image" "$ROOT_DIR/AnyKernel3"
cp -rf "$ROOT_DIR/modulebuild/"*.ko "$ROOT_DIR/AnyKernel3/modules/system/lib/modules"
cp -f "$ROOT_DIR/dtb.img" "$ROOT_DIR/AnyKernel3/dtb"

cd AnyKernel3 && zip -r9 "$ZIP_NAME" * -x .git README.md *placeholder

echo "Done. Zip created: $ZIP_NAME"

# --- Upload Success ---
if [ -n "$TG_BOT_TOKEN" ]; then
    # Changelog Logic
    if [ -f "$LAST_SHA_FILE" ]; then
        LAST_SHA=$(cat "$LAST_SHA_FILE")
        # Get log from last build to now
        CHANGELOG=$(git log --pretty=format:"%h: %s" "$LAST_SHA..HEAD")
        [ -z "$CHANGELOG" ] && CHANGELOG="No new commits."
    else
        # First run: just show last 5
        CHANGELOG=$(git log --pretty=format:"%h: %s" -n 5)
    fi

    CAPTION="Build complete: ${ZIP_NAME}

${CHANGELOG}"

    # Upload ZIP
    curl -s -F chat_id="$TG_CHAT_ID" -F document=@"$ZIP_NAME" -F caption="$CAPTION" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
    
    # Upload Config with unique name
    curl -s -F chat_id="$TG_CHAT_ID" \
         -F document=@"$CONFIG_FILE";filename="config-${GIT_SHA}.txt" \
         "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null

    # Update hash (using absolute path)
    git rev-parse HEAD > "$LAST_SHA_FILE"
fi
