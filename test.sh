#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO"; exit 1' ERR

############################################
# COMFYUI PROVISIONING SCRIPT (HYBRID)
# Docker Image: vastai/comfy:v0.13.0-cuda-13.1-py312
############################################

# Source venv
source /venv/main/bin/activate

# Directories
COMFY_DIR="${WORKSPACE}/ComfyUI"
MARKER="${WORKSPACE}/.custom_provisioned"

# Config
AUTO_UPDATE="${AUTO_UPDATE:-true}"

# Model URLs - Easy to customize
CHECKPOINT_MODELS=(
  "https://huggingface.co/xroli/DasiwaWAN22I2V14BLightspeed_synthseductionHighV9/resolve/main/DasiwaWAN22I2V14BLightspeed_synthseductionHighV9.safetensors?download=true"
  "https://huggingface.co/xroli/DasiwaWAN22I2V14BLightspeed_synthseductionHighV9/resolve/main/DasiwaWAN22I2V14BLightspeed_synthseductionLowV9.safetensors?download=true"
)

VAE_MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true"
)

TEXT_ENCODER_MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors"
)

CUSTOM_NODES_BUNDLE_URL="https://huggingface.co/xroli/4iBgRUx8osNO9q/resolve/main/custom_nodes_bundle.zip"

APT_PACKAGES=(
  "unzip"
)

############################################
# PREVENT DOUBLE RUN
############################################
if [[ -f "$MARKER" ]]; then
  echo "✅ Custom provisioning already completed, skipping"
  exit 0
fi

# Disable provisioning if file exists
if [[ -f /.noprovisioning ]]; then
  echo "⏭️  Provisioning disabled (/.noprovisioning found)"
  exit 0
fi

############################################
# NETWORK CHECK (HARD FAIL)
############################################
echo "⏳ Checking network connectivity..."
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
  echo "❌ Network unavailable after 40 attempts"
  exit 1
fi

############################################
# WAIT FOR COMFYUI DIRECTORY
############################################
echo "⏳ Waiting for ComfyUI to be available..."
for i in {1..60}; do
  if [[ -d "$COMFY_DIR" ]]; then
    echo "✅ ComfyUI directory found"
    break
  fi
  sleep 2
done

if [[ ! -d "$COMFY_DIR" ]]; then
  echo "❌ ComfyUI directory not found at $COMFY_DIR"
  exit 1
fi

############################################
# SANITY CHECKS
############################################
if [[ ! -x /venv/main/bin/python ]]; then
  echo "❌ Python executable not found or not executable"
  exit 1
fi

echo "========================================="
echo "🚀 COMFYUI PROVISIONING STARTING"
echo "========================================="
echo "Python: $(python --version)"
echo "ComfyUI: $COMFY_DIR"
echo "HF_TOKEN: ${HF_TOKEN:-(not set)}"
echo "CIVITAI_TOKEN: ${CIVITAI_TOKEN:-(not set)}"
echo "========================================="

############################################
# SYSTEM DEPENDENCIES
############################################
if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
  echo "📦 Installing system packages..."
  apt-get update && apt-get install -y "${APT_PACKAGES[@]}" && rm -rf /var/lib/apt/lists/*
  echo "✅ System packages installed"
fi

############################################
# ENSURE COMFYUI-MANAGER
############################################
echo "📦 Ensuring ComfyUI-Manager is installed..."
cd "$COMFY_DIR/custom_nodes"

if [[ ! -d "ComfyUI-Manager" ]]; then
  echo "  Installing ComfyUI-Manager from GitHub..."
  git clone https://github.com/ltdrdata/ComfyUI-Manager.git
  if [[ -f "ComfyUI-Manager/requirements.txt" ]]; then
    python -m pip install --no-cache-dir -r ComfyUI-Manager/requirements.txt || { echo "❌ Failed to install Manager requirements"; exit 1; }
  fi
  echo "✅ ComfyUI-Manager installed"
else
  if [[ "${AUTO_UPDATE,,}" != "false" ]]; then
    echo "  Updating ComfyUI-Manager..."
    cd ComfyUI-Manager
    git pull
    if [[ -f requirements.txt ]]; then
      python -m pip install --no-cache-dir -r requirements.txt
    fi
    cd ..
  fi
  echo "✅ ComfyUI-Manager is ready"
fi

############################################
# CUSTOM NODES BUNDLE
############################################
echo "📦 Installing custom nodes bundle..."
cd "$COMFY_DIR"

wget -c --content-disposition -O custom_nodes_bundle.zip.tmp "$CUSTOM_NODES_BUNDLE_URL" || \
  { echo "❌ Failed to download custom nodes bundle"; exit 1; }
mv custom_nodes_bundle.zip.tmp custom_nodes_bundle.zip

unzip -o custom_nodes_bundle.zip || { echo "❌ Failed to extract custom nodes bundle"; exit 1; }
rm custom_nodes_bundle.zip

echo "✅ Custom nodes bundle installed"

############################################
# INSTALL CUSTOM NODE REQUIREMENTS
############################################
echo "📦 Installing custom node pip requirements..."
INSTALLED_COUNT=0
for req in "$COMFY_DIR"/custom_nodes/*/requirements.txt; do
  if [[ -f "$req" ]]; then
    NODE_NAME=$(basename "$(dirname "$req")")
    echo "  Installing: $NODE_NAME"
    python -m pip install --no-cache-dir -r "$req" || { echo "❌ Failed to install $NODE_NAME requirements"; exit 1; }
    ((INSTALLED_COUNT++))
  fi
done
echo "✅ Installed requirements for $INSTALLED_COUNT custom node(s)"

############################################
# DOWNLOAD HELPER FUNCTION
############################################
function download_model() {
  local url="$1"
  local dest_dir="$2"
  local filename="${3:-}"
  
  mkdir -p "$dest_dir"
  cd "$dest_dir"
  
  # Extract filename if not provided
  if [[ -z "$filename" ]]; then
    filename=$(basename "$url" | cut -d'?' -f1)
  fi
  
  # Skip if already exists
  if [[ -f "$filename" ]]; then
    echo "  ⏭️  Already exists: $filename"
    return 0
  fi
  
  # Determine auth header
  local auth_header=""
  if [[ -n "${HF_TOKEN:-}" && "$url" =~ huggingface\.co ]]; then
    auth_header="--header='Authorization: Bearer $HF_TOKEN'"
  elif [[ -n "${CIVITAI_TOKEN:-}" && "$url" =~ civitai\.com ]]; then
    auth_header="--header='Authorization: Bearer $CIVITAI_TOKEN'"
  fi
  
  # Download with atomic operation
  echo "  ⬇️  Downloading: $filename"
  if [[ -n "$auth_header" ]]; then
    eval "wget -c --content-disposition -O ${filename}.tmp $auth_header '$url'" || \
      { echo "❌ Download failed: $filename"; exit 1; }
  else
    wget -c --content-disposition -O "${filename}.tmp" "$url" || \
      { echo "❌ Download failed: $filename"; exit 1; }
  fi
  
  mv "${filename}.tmp" "$filename"
  echo "  ✅ Downloaded: $filename"
}

############################################
# CHECKPOINT MODELS
############################################
if [[ ${#CHECKPOINT_MODELS[@]} -gt 0 ]]; then
  echo "📥 Downloading checkpoint models (${#CHECKPOINT_MODELS[@]})..."
  for model_url in "${CHECKPOINT_MODELS[@]}"; do
    download_model "$model_url" "$COMFY_DIR/models/checkpoints"
  done
  echo "✅ Checkpoint models ready"
fi

############################################
# VAE MODELS
############################################
if [[ ${#VAE_MODELS[@]} -gt 0 ]]; then
  echo "📥 Downloading VAE models (${#VAE_MODELS[@]})..."
  for model_url in "${VAE_MODELS[@]}"; do
    download_model "$model_url" "$COMFY_DIR/models/vae"
  done
  echo "✅ VAE models ready"
fi

############################################
# TEXT ENCODER MODELS
############################################
if [[ ${#TEXT_ENCODER_MODELS[@]} -gt 0 ]]; then
  echo "📥 Downloading text encoder models (${#TEXT_ENCODER_MODELS[@]})..."
  for model_url in "${TEXT_ENCODER_MODELS[@]}"; do
    download_model "$model_url" "$COMFY_DIR/models/text_encoders"
  done
  echo "✅ Text encoder models ready"
fi

############################################
# MARK SUCCESS
############################################
touch "$MARKER"

############################################
# COMPLETE
############################################
echo ""
echo "========================================="
echo "✅ PROVISIONING COMPLETE"
echo "========================================="
echo "ComfyUI is ready to start"
echo ""
