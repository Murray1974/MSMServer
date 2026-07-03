#!/usr/bin/env bash
# Run once on a fresh Ubuntu 22.04 VPS as root.
# Sets up Docker, creates a deploy user, clones the MSMServer repo, and boots the server.
#
# Usage:
#   chmod +x server-setup.sh && sudo bash server-setup.sh

set -euo pipefail

REPO_URL="${REPO_URL:-}"          # e.g. git@github.com:Murray1974/MSMServer.git
DEPLOY_USER="${DEPLOY_USER:-msm}" # OS user that runs the app
APP_DIR="/opt/msm"

# ── 1. System update ─────────────────────────────────────────────────────────
echo "[setup] Updating system packages…"
apt-get update -qq && apt-get upgrade -y -qq

# ── 2. Install Docker ────────────────────────────────────────────────────────
echo "[setup] Installing Docker…"
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

# ── 3. Create deploy user ────────────────────────────────────────────────────
echo "[setup] Creating deploy user '${DEPLOY_USER}'…"
if ! id "$DEPLOY_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"

# ── 4. Set up SSH authorized key for GitHub Actions ─────────────────────────
echo ""
echo "=========================================================="
echo " STEP: Add the GitHub Actions deploy public key below."
echo " Generate a key pair on your Mac:"
echo "   ssh-keygen -t ed25519 -C deploy@msm -f ~/.ssh/msm_deploy"
echo " Then paste the PUBLIC key (msm_deploy.pub) contents here:"
echo "=========================================================="
read -r -p "Paste public key: " PUBKEY

mkdir -p "/home/${DEPLOY_USER}/.ssh"
echo "$PUBKEY" >> "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
echo "[setup] SSH key installed for ${DEPLOY_USER}."

# ── 5. Clone repository ──────────────────────────────────────────────────────
if [[ -z "$REPO_URL" ]]; then
    echo ""
    read -r -p "Enter GitHub repo SSH URL (e.g. git@github.com:Murray1974/MSMServer.git): " REPO_URL
fi

echo "[setup] Cloning repo to ${APP_DIR}…"
mkdir -p "$(dirname "$APP_DIR")"
sudo -u "$DEPLOY_USER" git clone "$REPO_URL" "$APP_DIR"

# ── 6. Create .env from template ─────────────────────────────────────────────
echo ""
echo "=========================================================="
echo " STEP: Configure production environment variables."
echo " Edit ${APP_DIR}/.env with your live values."
echo "=========================================================="
cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${APP_DIR}/.env"
chmod 600 "${APP_DIR}/.env"
echo "[setup] .env created from template — edit it before starting the server."
echo "  nano ${APP_DIR}/.env"

# ── 7. First boot ────────────────────────────────────────────────────────────
echo ""
read -r -p "Start the server now? (you must edit .env first) [y/N]: " START
if [[ "$START" =~ ^[Yy]$ ]]; then
    cd "${APP_DIR}"
    sudo -u "$DEPLOY_USER" docker compose up --build -d
    echo "[setup] Server started. Check with: docker compose -f ${APP_DIR}/docker-compose.yml ps"
fi

echo ""
echo "=========================================================="
echo " Setup complete. Next steps:"
echo "  1. nano ${APP_DIR}/.env  (fill in real values)"
echo "  2. Add GitHub Actions secrets to Murray1974/MSMServer:"
echo "     DEPLOY_HOST    = this server's IP (134.122.111.4)"
echo "     DEPLOY_USER    = ${DEPLOY_USER}"
echo "     DEPLOY_SSH_KEY = contents of ~/.ssh/msm_deploy (private key)"
echo "  3. Push to main to trigger your first automated deploy."
echo "=========================================================="
