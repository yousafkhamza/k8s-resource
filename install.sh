#!/bin/bash

# k8s-resource - Kubernetes Resource Analyzer Installer
# This script installs the k8s-resource tool from Yousaf GitHub

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=====================================================${NC}"
echo -e "${GREEN}Kubernetes Resource Analyzer Installer${NC}"
echo -e "${BLUE}=====================================================${NC}"

# Check for required dependencies
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is required but not installed.${NC}"
        echo "Please install $1 before continuing."
        exit 1
    fi
}

echo -e "\n${YELLOW}Checking dependencies...${NC}"
check_dependency "curl"

# Determine installation directory
INSTALL_DIR=""
if [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
elif [ -w "$HOME/bin" ]; then
    INSTALL_DIR="$HOME/bin"
else
    # Create ~/bin if it doesn't exist
    mkdir -p "$HOME/bin"
    INSTALL_DIR="$HOME/bin"
    
    # Add to PATH if not already there
    if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
        echo -e "${YELLOW}Added $HOME/bin to your PATH in .bashrc${NC}"
        
        # Also try to add to .zshrc if it exists
        if [ -f "$HOME/.zshrc" ]; then
            echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc"
            echo -e "${YELLOW}Added $HOME/bin to your PATH in .zshrc${NC}"
        fi
    fi
fi

echo -e "${YELLOW}Installing to ${INSTALL_DIR}...${NC}"

# URL of the raw script on GitHub - Replace with your actual GitHub URL when you upload
SCRIPT_URL="https://raw.githubusercontent.com/yousafkhamza/k8s-resource/main/k8s-resource.sh"

# Download the script
echo -e "${YELLOW}Downloading k8s-resource script...${NC}"
curl -s -L "$SCRIPT_URL" -o "${INSTALL_DIR}/k8s-resource"

# Make the script executable
chmod +x "${INSTALL_DIR}/k8s-resource"

echo -e "\n${GREEN}Installation Complete!${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo -e "You can now run 'k8s-resource' from your terminal."
echo -e "For help, run 'k8s-resource --help'"
echo -e "${BLUE}=====================================================${NC}"

# Check if the installation directory is in PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo -e "\n${YELLOW}Warning: ${INSTALL_DIR} is not in your PATH.${NC}"
    echo "You may need to restart your terminal or add it manually."
    echo "You can also run the command using the full path: ${INSTALL_DIR}/k8s-resource"
fi

# Check for additional dependencies that will be needed by the tool
echo -e "\n${YELLOW}Checking for k8s-resource dependencies...${NC}"

missing_deps=false

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Warning: kubectl is required by k8s-resource but not installed.${NC}"
    echo "Please install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
    missing_deps=true
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Warning: jq is required by k8s-resource but not installed.${NC}"
    echo "Please install jq: https://stedolan.github.io/jq/download/"
    missing_deps=true
fi

if ! command -v bc &> /dev/null; then
    echo -e "${RED}Warning: bc is required by k8s-resource but not installed.${NC}"
    echo "Please install bc using your package manager (apt-get install bc, yum install bc, etc.)"
    missing_deps=true
fi

if [ "$missing_deps" = true ]; then
    echo -e "\n${YELLOW}Please install the missing dependencies before using k8s-resource.${NC}"
else
    echo -e "${GREEN}All dependencies satisfied!${NC}"
fi