#!/bin/bash
set -e
# --- variables (customize via userdata templating) ---
REPO_URL="https://github.com/your-username/your-repo.git"
BRANCH="main"
APP_DIR="/opt/app/backend"
NODE_VERSION="18"

# update & install
yum update -y || apt-get update -y
# Install Node (Amazon Linux 2 example) - adapt per AMI
curl -sL https://rpm.nodesource.com/setup_${NODE_VERSION}.x | bash -
yum install -y nodejs git nginx

# create app dir and pull code
mkdir -p ${APP_DIR}
cd /opt/app || exit 1
git clone --depth 1 --branch ${BRANCH} ${REPO_URL} repo || true
cd repo/backend || exit 1
npm ci

# create a dedicated user
useradd -m appuser || true
chown -R appuser:appuser /opt/app

# Install pm2 globally and start backend
npm install -g pm2
pm2 start server.js --name backend --watch --cwd /opt/app/repo/backend -- -q
pm2 save
pm2 startup systemd -u appuser --hp /home/appuser

# Configure Nginx as reverse proxy for /api (optional if ALB calls instance directly)
cat > /etc/nginx/conf.d/backend.conf <<'NGX'
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    location /health {
        proxy_pass http://127.0.0.1:4000/api/health;
    }
}
NGX

systemctl enable nginx
systemctl restart nginx
