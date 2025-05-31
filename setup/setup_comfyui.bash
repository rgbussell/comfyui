#!/bin/bash

# Script to install ComfyUI in a virtual environment on Ubuntu
# Tested for Ubuntu 20.04, 22.04, and later
# Requires NVIDIA GPU with CUDA support
# Uses CUDA 12.8 as per ComfyUI README, includes torchaudio with fallback
# Minimizes sudo usage and optimizes for low VRAM

# Exit on any error
set -e

# Check for NVIDIA GPU and CUDA support
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "NVIDIA GPU not detected or nvidia-smi not installed. ComfyUI requires CUDA support."
    exit 1
fi

# Check GPU VRAM (recommend ~6 GB for basic models)
GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv -i 0 | tail -n 1 | awk '{print $1}')
if [ "$GPU_VRAM" -lt 6000 ]; then
    echo "Warning: GPU VRAM is ${GPU_VRAM}MB. ComfyUI recommends ~6GB for basic models."
    read -p "Continue anyway? (y/n): " CONTINUE
    if [ "$CONTINUE" != "y" ]; then
        exit 1
    fi
fi

# Check available memory (RAM + swap, recommend ~16 GB)
TOTAL_MEM=$(free -m | awk '/Mem:/ {print $2}')
TOTAL_SWAP=$(free -m | awk '/Swap:/ {print $2}')
TOTAL_AVAILABLE=$((TOTAL_MEM + TOTAL_SWAP))
if [ "$TOTAL_AVAILABLE" -lt 16000 ]; then
    echo "Warning: Total memory (RAM + swap) is ${TOTAL_AVAILABLE}MB, but ~16GB is recommended."
    echo "Consider increasing swap or adding RAM."
    read -p "Continue anyway? (y/n): " CONTINUE
    if [ "$CONTINUE" != "y" ]; then
        exit 1
    fi
fi

# Detect Ubuntu version
UBUNTU_VERSION=$(lsb_release -cs)
case "$UBUNTU_VERSION" in
    "focal") CUDA_REPO="ubuntu2004" ;;
    "jammy") CUDA_REPO="ubuntu2204" ;;
    "noble") CUDA_REPO="ubuntu2404" ;;
    *)
        echo "Unsupported Ubuntu version: $UBUNTU_VERSION. Supported: focal (20.04), jammy (22.04), noble (24.04)."
        exit 1
        ;;
esac
echo "Detected Ubuntu version: $UBUNTU_VERSION (using CUDA repo: $CUDA_REPO)"

# Clean up existing CUDA repositories
echo "Cleaning up existing CUDA repositories..."
sudo rm -f /etc/apt/sources.list.d/cuda*.list
sudo rm -f /etc/apt/preferences.d/cuda-repository-pin-600
sudo apt-key del 3bf863cc 2>/dev/null || true
sudo apt-get update

# Update package list and install prerequisites with sudo
echo "Updating package list and installing prerequisites..."
sudo apt-get update
sudo apt-get install -y git python3 python3-venv python3-pip wget unzip
# Install libtinfo5 if missing (from previous LTX-Video issue)
if ! dpkg -l | grep -q libtinfo5; then
    echo "Installing libtinfo5..."
    sudo apt-get install -y libtinfo5 || {
        echo "Adding Ubuntu 20.04 repository for libtinfo5..."
        sudo add-apt-repository "deb http://archive.ubuntu.com/ubuntu focal main universe"
        sudo apt-get update
        sudo apt-get install -y libtinfo5
        sudo add-apt-repository -r "deb http://archive.ubuntu.com/ubuntu focal main universe"
        sudo apt-get update
    }
fi

# Install CUDA Toolkit 12.8 if not already installed
CUDA_VERSION="12-8"
if ! nvcc --version | grep -q "release 12.8"; then
    echo "Installing CUDA Toolkit $CUDA_VERSION..."
    wget https://developer.download.nvidia.com/compute/cuda/repos/$CUDA_REPO/x86_64/cuda-$CUDA_REPO.pin
    sudo mv cuda-$CUDA_REPO.pin /etc/apt/preferences.d/cuda-repository-pin-600
    sudo apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/$CUDA_REPO/x86_64/3bf863cc.pub
    sudo add-apt-repository "deb https://developer.download.nvidia.com/compute/cuda/repos/$CUDA_REPO/x86_64/ /"
    sudo apt-get update
    sudo apt-get install -y cuda-toolkit-$CUDA_VERSION --no-install-recommends
fi

# Clone the ComfyUI repository as regular user
echo "Cloning ComfyUI repository..."
if [ -d "ComfyUI" ]; then
    rm -rf ComfyUI
fi
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI

# Create and activate a virtual environment as regular user
echo "Creating and activating virtual environment..."
rm -rf venv # Ensure clean environment
python3 -m venv venv || { echo "Failed to create virtual environment"; exit 1; }
if [ -f venv/bin/activate ]; then
    . ./venv/bin/activate || { echo "Failed to activate virtual environment"; exit 1; }
else
    echo "Virtual environment activation script not found"
    exit 1
fi

# Upgrade pip and install dependencies
echo "Installing Python dependencies..."
pip install --upgrade pip
# Install PyTorch with CUDA 12.8 (per ComfyUI README, with torchaudio and fallback)
if ! pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu128; then
    echo "Warning: torchaudio installation failed. Proceeding with torch and torchvision only."
    pip install torch torchvision --extra-index-url https://download.pytorch.org/whl/cu128
fi
# Install safetensors explicitly
pip install safetensors
# Install requirements.txt (first pass)
pip install -r requirements.txt
# Re-run requirements.txt to ensure all dependencies are satisfied
pip install -r requirements.txt

# Download a sample model (DreamShaper 8, ~2 GB)
echo "Downloading DreamShaper 8 model..."
MODEL_DIR="models/checkpoints"
mkdir -p $MODEL_DIR
wget -P $MODEL_DIR https://huggingface.co/Lykon/DreamShaper/resolve/main/DreamShaper_8_pruned.safetensors

# Verify installation
echo "Verifying installation..."
if python -c "import torch; import safetensors; import torchaudio; print('Dependencies installed successfully')" >/dev/null 2>&1; then
    echo "ComfyUI dependencies installed successfully."
else
    echo "Warning: Some dependencies (e.g., torchaudio) may not be installed, but ComfyUI may still work."
fi

# Set environment variable for memory optimization
echo "Setting PYTORCH_CUDA_ALLOC_CONF for memory optimization..."
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# Provide instructions to run ComfyUI
echo "Installation complete! You can now run ComfyUI."
echo "To start ComfyUI:"
echo "  cd /home/rbussell/repos/ltxv/ltxv/setup/ComfyUI"
echo "  . ./venv/bin/activate"
echo "  export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
echo "  python main.py --force-fp16 --lowvram"
echo "Access the web interface at http://localhost:8188"

# Clean up
echo "Cleaning up temporary files..."
rm -f cuda-$CUDA_REPO.pin

echo "Setup complete! Activate the virtual environment with '. ComfyUI/venv/bin/activate' to use ComfyUI."