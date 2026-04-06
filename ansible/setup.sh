#!/usr/bin/env bash
# setup.sh — Create Python venv and install Ansible + dependencies
# Run from the ansible/ directory
set -euo pipefail

VENV_DIR=".venv"

echo "=== Setting up Ansible environment ==="

# Create venv
if [[ ! -d "$VENV_DIR" ]]; then
  echo "[1/3] Creating Python virtual environment..."
  python3 -m venv "$VENV_DIR"
else
  echo "[1/3] Virtual environment already exists"
fi

# Activate
source "$VENV_DIR/bin/activate"

# Install packages
echo "[2/3] Installing Ansible and dependencies..."
pip install --upgrade pip > /dev/null
pip install ansible ansible-core kubernetes > /dev/null 2>&1

# Install Ansible collections
echo "[3/3] Installing Ansible collections..."
ansible-galaxy collection install kubernetes.core community.general ansible.posix --force > /dev/null 2>&1

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Activate the environment:"
echo "  source ${VENV_DIR}/bin/activate"
echo ""
echo "Verify:"
echo "  ansible --version"
echo "  ansible-inventory --list"
echo ""
echo "Run a playbook:"
echo "  cd ansible/"
echo "  ansible-playbook playbooks/01-create-vms.yml"
