#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: SeaO2
# License: MIT | https://github.com/community-scripts/DevScripts/raw/main/LICENSE
# Source: https://github.com/Grashjs/cmms

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

JAVA_VERSION="17" setup_java
NODE_VERSION="22" setup_nodejs

# after setup_java, so Temurin satisfies maven's Java dependency instead of pulling in OpenJDK
msg_info "Installing Dependencies"
$STD apt install -y nginx maven
msg_ok "Installed Dependencies"

PG_VERSION="16" setup_postgresql
PG_DB_NAME="atlas" PG_DB_USER="atlas" PG_DB_EXTENSIONS="unaccent" setup_postgresql_db
fetch_and_deploy_gh_release "silo_s3" "pgsty/silo" "binary"

msg_info "Configuring Silo (S3 storage)"
mkdir -p /opt/atlas-cmms_data/storage
chown silo:silo /opt/atlas-cmms_data/storage
STORAGE_PASS=$(random_password 32)
cat <<EOF >/etc/default/silo
MINIO_VOLUMES="/opt/atlas-cmms_data/storage"
MINIO_OPTS="--address 127.0.0.1:9000 --console-address 127.0.0.1:9001"
MINIO_ROOT_USER="atlas"
MINIO_ROOT_PASSWORD="${STORAGE_PASS}"
EOF
chmod 600 /etc/default/silo
systemctl enable -q --now silo
msg_ok "Configured Silo (S3 storage)"

fetch_and_deploy_gh_release "atlas-cmms" "Grashjs/cmms" "tarball"

msg_info "Building Atlas CMMS Backend"
cd /opt/atlas-cmms/api
$STD mvn -B -DskipTests package
cp target/*.jar /opt/atlas-cmms/atlas-cmms-api.jar
rm -rf target
msg_ok "Built Atlas CMMS Backend"

msg_info "Building Atlas CMMS Frontend"
cd /opt/atlas-cmms/frontend
$STD npm ci --legacy-peer-deps
export NODE_OPTIONS="--max-old-space-size=4096"
$STD npm run build
rm -rf node_modules
msg_ok "Built Atlas CMMS Frontend"

msg_info "Configuring Atlas CMMS"
# The backend hardcodes /app/static/{images,config} for custom logos and license files.
mkdir -p /opt/atlas-cmms_data/static/images /opt/atlas-cmms_data/static/config
ln -s /opt/atlas-cmms_data /app
cat <<EOF >/opt/atlas-cmms_data/.env
DB_URL=127.0.0.1:5432/${PG_DB_NAME}
DB_USER=${PG_DB_USER}
DB_PWD=${PG_DB_PASS}
JWT_SECRET_KEY=$(openssl rand -base64 32)
SPRING_PROFILES_ACTIVE=

PUBLIC_API_URL=http://${LOCAL_IP}/api
PUBLIC_FRONT_URL=http://${LOCAL_IP}
ENABLE_CORS=false
SINGLE_INGRESS=true
TRUSTED_PROXY_IPS=

STORAGE_TYPE=minio
MINIO_ENDPOINT=http://127.0.0.1:9000
PUBLIC_MINIO_ENDPOINT=http://${LOCAL_IP}/storage
MINIO_BUCKET=atlas-bucket
MINIO_ACCESS_KEY=atlas
MINIO_SECRET_KEY=${STORAGE_PASS}

ENABLE_EMAIL_NOTIFICATIONS=false
INVITATION_VIA_EMAIL=false
ENABLE_MAIL_HEALTH_CHECK=false
MAIL_TYPE=smtp
MAIL_RECIPIENTS=
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=
SMTP_PWD=
SMTP_FROM=

ALLOWED_ORGANIZATION_ADMINS=
ENABLE_SSO=false
OAUTH2_PROVIDER=
OAUTH2_CLIENT_ID=
OAUTH2_CLIENT_SECRET=
LDAP_ENABLED=false
LICENSE_KEY=
LOGO_PATHS=
CUSTOM_COLORS=
BRAND_CONFIG=
EOF
chmod 600 /opt/atlas-cmms_data/.env
cat <<'EOF' >/opt/atlas-cmms_data/runtime-env.js
window.__RUNTIME_CONFIG__ = {
  "API_URL": "/api",
  "HOME_URL": "https://atlas-cmms.com",
  "INVITATION_VIA_EMAIL": "false",
  "CLOUD_VERSION": "false",
  "ENABLE_SSO": "false",
  "OAUTH2_PROVIDER": "",
  "LDAP_ENABLED": "false",
  "GOOGLE_KEY": "",
  "GOOGLE_TRACKING_ID": "",
  "LOGO_PATHS": "",
  "CUSTOM_COLORS": "",
  "BRAND_CONFIG": "",
  "DEMO_LINK": "",
  "PADDLE_SECRET_TOKEN": "",
  "PADDLE_ENVIRONMENT": "production",
  "RECAPTCHA_SITE_KEY": "",
  "CLARITY_ID": "",
  "SENTRY_DSN": "",
  "SENTRY_ENVIRONMENT": "production",
  "SENTRY_RELEASE": ""
};
EOF
msg_ok "Configured Atlas CMMS"

msg_info "Configuring Nginx"
cat <<'EOF' >/etc/nginx/sites-available/atlas-cmms
server {
    listen 80;
    server_name _;
    client_max_body_size 200M;

    root /opt/atlas-cmms/frontend/build;
    index index.html;

    location = /runtime-env.js {
        alias /opt/atlas-cmms_data/runtime-env.js;
    }

    location / {
        try_files $uri $uri/ /index.html;
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location /storage/ {
        proxy_pass http://127.0.0.1:9000/;
        proxy_set_header Host 127.0.0.1:9000;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        client_max_body_size 500M;
    }
}
EOF
nginx_enable_site "atlas-cmms"
msg_ok "Configured Nginx"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/atlas-cmms.service
[Unit]
Description=Atlas CMMS Backend
After=network.target postgresql.service silo.service
Wants=postgresql.service silo.service

[Service]
Type=simple
WorkingDirectory=/opt/atlas-cmms
EnvironmentFile=/opt/atlas-cmms_data/.env
ExecStart=/usr/bin/java --add-opens=java.base/java.lang=ALL-UNNAMED -jar /opt/atlas-cmms/atlas-cmms-api.jar
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now atlas-cmms
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
