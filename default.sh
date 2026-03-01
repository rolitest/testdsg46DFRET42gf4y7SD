#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO"; exit 1' ERR

############################################
# INDEX
############################################
# Docker Image: vastai/comfy:v0.13.0-cuda-13.1-py312
# 1. GLOBAL CONFIG (VAST SAFE)
# 2. PREVENT DOUBLE RUN
# 3. WAIT FOR NETWORK (DNS IS OFTEN LATE)
# 4. WAIT FOR COMFYUI + MANAGER
# 5. BASIC SANITY
# 6. SYSTEM DEPENDENCIES
# 7. CUSTOM NODES BUNDLE
# 8. CHECKPOINT MODEL
# 9. VAE
# 10. TEXT ENCODERS
# 11. MARK SUCCESS
############################################

############################################
# GLOBAL CONFIG (VAST SAFE)
############################################
VENV="/venv/main"
WORKSPACE="/workspace"
COMFY_DIR="$WORKSPACE/ComfyUI"
MARKER="$WORKSPACE/.custom_provisioned"

PYTHON="$VENV/bin/python"
CMCLI="$COMFY_DIR/custom_nodes/ComfyUI-Manager/cm-cli.py"

############################################
# PREVENT DOUBLE RUN
############################################
if [[ -f "$MARKER" ]]; then
  echo "✅ Custom provisioning already completed, skipping"
  exit 0
fi

############################################
# WAIT FOR NETWORK (DNS IS OFTEN LATE)
############################################
echo "⏳ Waiting for network..."
NETWORK_OK=false
for i in {1..40}; do
  if getent hosts github.com >/dev/null 2>&1; then
    NETWORK_OK=true
    echo "✅ Network ready"
    break
  fi
  sleep 2
done

if [[ "$NETWORK_OK" != true ]]; then
  echo "❌ Network unavailable"
  exit 1
fi

############################################
# WAIT FOR COMFYUI + MANAGER
############################################
echo "⏳ Waiting for ComfyUI..."
for i in {1..60}; do
  if [[ -d "$COMFY_DIR" ]]; then
    echo "✅ ComfyUI detected"
    break
  fi
  sleep 2
done

if [[ ! -d "$COMFY_DIR" ]]; then
  echo "❌ ComfyUI not found, aborting"
  exit 1
fi

echo "📦 Ensuring ComfyUI-Manager is installed"
cd "$COMFY_DIR/custom_nodes"

if [[ ! -d "ComfyUI-Manager" ]]; then
  echo "Installing ComfyUI-Manager..."
  git clone https://github.com/ltdrdata/ComfyUI-Manager.git
  $PYTHON -m pip install -r ComfyUI-Manager/requirements.txt || { echo "Failed to install Manager requirements"; exit 1; }
else
  echo "✅ ComfyUI-Manager already exists"
fi

############################################
# BASIC SANITY
############################################
if [[ ! -x "$PYTHON" ]]; then
  echo "❌ Python not found at $PYTHON"
  exit 1
fi

echo "========================================="
echo "🚀 Custom provisioning started"
echo "Python: $($PYTHON --version)"
echo "ComfyUI: $COMFY_DIR"
echo "Docker: vastai/comfy:v0.13.0-cuda-13.1-py312"
echo "========================================="

############################################
# SYSTEM DEPENDENCIES
############################################
echo "📦 Installing system dependencies"
apt-get update && apt-get install -y unzip && rm -rf /var/lib/apt/lists/*

############################################
# CUSTOM NODES BUNDLE
############################################
echo "📦 Downloading custom nodes bundle"
cd "$COMFY_DIR"
wget -c \
"https://huggingface.co/xroli/4iBgRUx8osNO9q/resolve/main/custom_nodes_bundle.zip" \
-O custom_nodes_bundle.zip

echo "📦 Extracting custom nodes"
unzip -o custom_nodes_bundle.zip
rm custom_nodes_bundle.zip

echo "📦 Installing custom node requirements"
for req in "$COMFY_DIR"/custom_nodes/*/requirements.txt; do
  if [[ -f "$req" ]]; then
    echo "Installing $req"
    $PYTHON -m pip install -r "$req" || { echo "Failed to install $req"; exit 1; }
  fi
done

############################################
# CHECKPOINT MODEL
############################################
echo "📥 Checkpoint model"
mkdir -p "$COMFY_DIR/models/checkpoints"
cd "$COMFY_DIR/models/checkpoints"

[[ -f DasiwaWAN22I2V14BLightspeed_synthseductionHighV9.safetensors ]] || {
  wget -c --content-disposition -O DasiwaWAN22I2V14BLightspeed_synthseductionHighV9.safetensors.tmp \
  "https://huggingface.co/xroli/DasiwaWAN22I2V14BLightspeed_synthseductionHighV9/resolve/main/DasiwaWAN22I2V14BLightspeed_synthseductionHighV9.safetensors?download=true" || { echo "Download failed"; exit 1; }
  mv DasiwaWAN22I2V14BLightspeed_synthseductionHighV9.safetensors.tmp DasiwaWAN22I2V14BLightspeed_synthseductionHighV9.safetensors
}

[[ -f DasiwaWAN22I2V14BLightspeed_synthseductionLowV9.safetensors ]] || {
  wget -c --content-disposition -O DasiwaWAN22I2V14BLightspeed_synthseductionLowV9.safetensors.tmp \
  "https://huggingface.co/xroli/DasiwaWAN22I2V14BLightspeed_synthseductionHighV9/resolve/main/DasiwaWAN22I2V14BLightspeed_synthseductionLowV9.safetensors?download=true" || { echo "Download failed"; exit 1; }
  mv DasiwaWAN22I2V14BLightspeed_synthseductionLowV9.safetensors.tmp DasiwaWAN22I2V14BLightspeed_synthseductionLowV9.safetensors
}

############################################
# VAE
############################################
echo "📥 VAE"
mkdir -p "$COMFY_DIR/models/vae"
cd "$COMFY_DIR/models/vae"

[[ -f wan_2.1_vae.safetensors ]] || {
  wget -c --content-disposition -O wan_2.1_vae.safetensors.tmp \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true" || { echo "Download failed"; exit 1; }
  mv wan_2.1_vae.safetensors.tmp wan_2.1_vae.safetensors
}

############################################
# TEXT ENCODERS
############################################
echo "📥 Text Encoders"
mkdir -p "$COMFY_DIR/models/text_encoders"
cd "$COMFY_DIR/models/text_encoders"

[[ -f umt5_xxl_fp16.safetensors ]] || {
  wget -c --content-disposition -O umt5_xxl_fp16.safetensors.tmp \
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors" || { echo "Download failed"; exit 1; }
  mv umt5_xxl_fp16.safetensors.tmp umt5_xxl_fp16.safetensors
}

############################################
# MARK SUCCESS
############################################
touch "$MARKER"

echo "========================================="
echo "✅ Custom provisioning COMPLETE"
echo "ComfyUI will continue starting normally"
echo "========================================="
