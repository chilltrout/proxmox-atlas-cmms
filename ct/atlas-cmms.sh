#!/usr/bin/env bash
_CS_DEFAULT_URL="https://raw.githubusercontent.com/chilltrout/proxmox-atlas-cmms/main"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

# Copyright (c) 2021-2026 community-scripts ORG
# Author: SeaO2
# License: MIT | https://github.com/community-scripts/DevScripts/raw/main/LICENSE
# Source: https://github.com/Grashjs/cmms

APP="Atlas-CMMS"
var_tags="${var_tags:-cmms;maintenance;business}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-6144}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
#var_arm64="${var_arm64:-yes}" # built from source; Temurin 17, Node 22, PostgreSQL 16, nginx, maven and the Silo arm64 .deb all ship arm64, but not yet run on arm64

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/atlas-cmms ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "silo_s3" "pgsty/silo"; then
    msg_info "Stopping Silo"
    systemctl stop silo
    msg_ok "Stopped Silo"

    var_appversion= DPKG_FORCE_CONFOLD=1 fetch_and_deploy_gh_release "silo_s3" "pgsty/silo" "binary"

    msg_info "Starting Silo"
    systemctl start silo
    msg_ok "Started Silo"
    msg_ok "Updated successfully!"
  fi

  if check_for_gh_release "atlas-cmms" "Grashjs/cmms"; then
    msg_info "Stopping Atlas CMMS"
    systemctl stop atlas-cmms
    msg_ok "Stopped Atlas CMMS"

    JAVA_VERSION="17" setup_java
    ensure_dependencies maven
    NODE_VERSION="22" setup_nodejs

    CLEAN_INSTALL=1 CLEAN_INSTALL_KEEP="atlas-cmms-api.jar frontend/build" fetch_and_deploy_gh_release "atlas-cmms" "Grashjs/cmms" "tarball"

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

    msg_info "Starting Atlas CMMS"
    systemctl start atlas-cmms
    msg_ok "Started Atlas CMMS"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}${CL}"
