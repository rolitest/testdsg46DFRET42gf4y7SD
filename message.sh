#!/usr/bin/env bash
set -euo pipefail

############################################
# COMFYUI PROVISIONING SCRIPT (VAST SAFE)
# Base Image example: vastai/comfy:v0.13.0-cuda-13.1-py312
############################################

############################################
# GLOBAL CONFIG (VAST SAFE)
############################################
VENV="/venv/main"
WORKSPACE="/workspace"
COMFY_DIR="$WORKSPACE/ComfyUI"
MARKER="$WORKSPACE/.custom_provisioned"

PYTHON="$VENV/bin/python"

# Optional behavior
AUTO_UPDATE="${AUTO_UPDATE:-true}"

############################################
# MODEL URLS (EASY TO CUSTOMIZE)
############################################
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

############################################
# DERIVED PATHS
############################################
CM_MANAGER_DIR="$COMFY_DIR/custom_nodes/ComfyUI-Manager"
CMCLI="$CM_MANAGER_DIR/cm-cli.py"

############################################
# PREVENT DOUBLE RUN
############################################
if [[ -f "$MARKER" ]]; then
  echo "✅ Custom provisioning already completed, skipping"
  exit 0
fi

############################################
# DISABLE PROVISIONING IF REQUESTED
############################################
if [[ -f /.noprovisioning ]]; then
  echo "⏭️  Provisioning disabled (/.noprovisioning found)"
  exit 0
fi

############################################
# WAIT FOR NETWORK (DNS IS OFTEN LATE)
############################################
echo "⏳ Waiting for network..."
for i in {1..40}; do
  if getent hosts github.com >/dev/null 2>&1; then
    echo "✅ Network ready"
    break
  fi
  sleep 2
done

############################################
# WAIT FOR COMFYUI DIRECTORY
############################################
echo "⏳ Waiting for ComfyUI directory..."
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
echo "HF_TOKEN: ${HF_TOKEN:-(not set)}"
echo "CIVITAI_TOKEN: ${CIVITAI_TOKEN:-(not set)}"
echo "AUTO_UPDATE: $AUTO_UPDATE"
echo "========================================="

############################################
# ENSURE COMFYUI-MANAGER EXISTS (VAST SAFE)
# - If it's already present, optionally update it.
# - If it's missing, try to clone it (requires git present).
############################################
echo "📦 Ensuring ComfyUI-Manager is installed..."
mkdir -p "$COMFY_DIR/custom_nodes"
cd "$COMFY_DIR/custom_nodes"

if [[ ! -d "$CM_MANAGER_DIR" ]]; then
  echo "  ComfyUI-Manager missing, installing from GitHub..."
  command -v git >/dev/null 2>&1 || { echo "❌ git not installed; cannot clone ComfyUI-Manager"; exit 1; }
  git clone https://github.com/ltdrdata/ComfyUI-Manager.git

  if [[ -f "$CM_MANAGER_DIR/requirements.txt" ]]; then
    $PYTHON -m pip install --no-cache-dir -r "$CM_MANAGER_DIR/requirements.txt" || {
      echo "❌ Failed to install ComfyUI-Manager requirements"
      exit 1
    }
  fi
  echo "✅ ComfyUI-Manager installed"
else
  if [[ "${AUTO_UPDATE,,}" != "false" ]]; then
    echo "  Updating ComfyUI-Manager..."
    command -v git >/dev/null 2>&1 || { echo "❌ git not installed; cannot update ComfyUI-Manager"; exit 1; }
    cd "$CM_MANAGER_DIR"
    git pull || true
    if [[ -f requirements.txt ]]; then
      $PYTHON -m pip install --no-cache-dir -r requirements.txt || true
    fi
    cd "$COMFY_DIR/custom_nodes"
  fi
  echo "✅ ComfyUI-Manager is ready"
fi

############################################
# WAIT FOR MANAGER CLI
############################################
echo "⏳ Waiting for ComfyUI-Manager CLI..."
for i in {1..30}; do
  if [[ -f "$CMCLI" ]]; then
    echo "✅ ComfyUI-Manager CLI detected"
    break
  fi
  sleep 1
done

if [[ ! -f "$CMCLI" ]]; then
  echo "❌ ComfyUI-Manager CLI not found at $CMCLI"
  exit 1
fi

############################################
# CUSTOM NODES BUNDLE (ZIP)
############################################
echo "📦 Installing custom nodes bundle..."
cd "$COMFY_DIR"

command -v unzip >/dev/null 2>&1 || { echo "❌ unzip not installed (install it in your image or add it)"; exit 1; }
command -v wget  >/dev/null 2>&1 || { echo "❌ wget not installed (install it in your image or add it)"; exit 1; }

wget -c --content-disposition -O custom_nodes_bundle.zip.tmp "$CUSTOM_NODES_BUNDLE_URL" || {
  echo "❌ Failed to download custom nodes bundle"
  exit 1
}
mv custom_nodes_bundle.zip.tmp custom_nodes_bundle.zip

unzip -o custom_nodes_bundle.zip || {
  echo "❌ Failed to extract custom nodes bundle"
  exit 1
}
rm -f custom_nodes_bundle.zip

echo "✅ Custom nodes bundle installed"

############################################
# INSTALL CUSTOM NODE REQUIREMENTS
############################################
echo "📦 Installing custom node pip requirements..."
INSTALLED_COUNT=0

shopt -s nullglob
for req in "$COMFY_DIR"/custom_nodes/*/requirements.txt; do
  NODE_NAME="$(basename "$(dirname "$req")")"
  echo "  Installing: $NODE_NAME"
  $PYTHON -m pip install --no-cache-dir -r "$req" || {
    echo "❌ Failed to install $NODE_NAME requirements"
    exit 1
  }
  INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
done
shopt -u nullglob

echo "✅ Installed requirements for $INSTALLED_COUNT custom node(s)"

############################################
# DOWNLOAD HELPER (AUTH SUPPORT)
############################################
download_model () {
  local url="$1"
  local dest_dir="$2"
  local filename="${3:-}"

  mkdir -p "$dest_dir"
  cd "$dest_dir"

  if [[ -z "$filename" ]]; then
    filename="$(basename "$url" | cut -d'?' -f1)"
  fi

  if [[ -f "$filename" ]]; then
    echo "  ⏭️  Already exists: $filename"
    return 0
  fi

  local tmp="${filename}.tmp"

  # Build wget args (avoid eval)
  local -a WGET_ARGS
  WGET_ARGS=(-c --content-disposition -O "$tmp")

  if [[ -n "${HF_TOKEN:-}" && "$url" == *"huggingface.co"* ]]; then
    WGET_ARGS+=(--header "Authorization: Bearer $HF_TOKEN")
  elif [[ -n "${CIVITAI_TOKEN:-}" && "$url" == *"civitai.com"* ]]; then
    WGET_ARGS+=(--header "Authorization: Bearer $CIVITAI_TOKEN")
  fi

  echo "  ⬇️  Downloading: $filename"
  wget "${WGET_ARGS[@]}" "$url" || { echo "❌ Download failed: $filename"; exit 1; }

  mv "$tmp" "$filename"
  echo "  ✅ Downloaded: $filename"
}

############################################
# CHECKPOINT MODELS
############################################
if [[ "${#CHECKPOINT_MODELS[@]}" -gt 0 ]]; then
  echo "📥 Downloading checkpoint models (${#CHECKPOINT_MODELS[@]})..."
  for model_url in "${CHECKPOINT_MODELS[@]}"; do
    download_model "$model_url" "$COMFY_DIR/models/checkpoints"
  done
  echo "✅ Checkpoint models ready"
fi

############################################
# VAE MODELS
############################################
if [[ "${#VAE_MODELS[@]}" -gt 0 ]]; then
  echo "📥 Downloading VAE models (${#VAE_MODELS[@]})..."
  for model_url in "${VAE_MODELS[@]}"; do
    download_model "$model_url" "$COMFY_DIR/models/vae"
  done
  echo "✅ VAE models ready"
fi

############################################
# TEXT ENCODER MODELS
############################################
if [[ "${#TEXT_ENCODER_MODELS[@]}" -gt 0 ]]; then
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

echo "========================================="
echo "✅ Custom provisioning COMPLETE"
echo "ComfyUI will continue starting normally"
echo "========================================="