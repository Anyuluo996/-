#!/bin/bash

INSTALL_DIR="/usr/local/bin/easytier"
SERVICE_NAME="easytier.service"
GITHUB_REPO="EasyTier/EasyTier"
CONFIG_PATH="${INSTALL_DIR}/config.yaml"

# --- 辅助函数 ---
log_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; exit 1; }

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 权限运行: sudo ./install_easytier.sh"
fi

# 1. 检查依赖
log_info "正在检查系统依赖..."
MISSING_DEPS=()
for cmd in curl unzip jq grep awk; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    log_warn "正在安装缺少的依赖: ${MISSING_DEPS[*]}"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y "${MISSING_DEPS[@]}"
    elif command -v yum &> /dev/null; then
        yum install -y "${MISSING_DEPS[@]}"
    elif command -v dnf &> /dev/null; then
        dnf install -y "${MISSING_DEPS[@]}"
    else
        log_error "无法自动安装依赖，请手动安装: ${MISSING_DEPS[*]}"
    fi
fi

# 2. 获取 GitHub 最新版本信息 (同时获取 URL 和 Tag)
log_info "正在查询 GitHub 最新版本..."
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
API_RESPONSE=$(curl -s "$API_URL")

# 提取下载链接
DOWNLOAD_URL=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | test("easytier-linux-x86_64-v.*\\.zip$")) | .browser_download_url')
# 提取最新版本号 (例如 v1.2.0)
REMOTE_VERSION_TAG=$(echo "$API_RESPONSE" | jq -r '.tag_name')
# 去除 v 前缀用于比较 (v1.2.0 -> 1.2.0)
REMOTE_VER_NUM=$(echo "$REMOTE_VERSION_TAG" | sed 's/^v//')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    log_error "无法获取下载链接，请检查网络或 GitHub API 限制。"
fi

# 3. 版本检测与升级判断
NEED_INSTALL=true

if [ -f "${INSTALL_DIR}/easytier-core" ]; then
    # 获取本地版本，通常输出格式为 "easytier-core 1.2.0" 或 "1.2.0"
    # 使用 grep -oE 提取数字版本号
    LOCAL_VER_RAW=$(${INSTALL_DIR}/easytier-core -V 2>&1)
    LOCAL_VER_NUM=$(echo "$LOCAL_VER_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

    log_info "版本检测:"
    echo "   - 本地版本: ${LOCAL_VER_NUM}"
    echo "   - 最新版本: ${REMOTE_VER_NUM}"

    if [ "$LOCAL_VER_NUM" == "$REMOTE_VER_NUM" ]; then
        echo "------------------------------------------------"
        echo -e "\033[32m当前已是最新版本，无需更新。\033[0m"
        echo "脚本结束。"
        exit 0
    else
        log_warn "发现新版本！准备进行升级..."
    fi
else
    log_info "未检测到 easytier-core，准备执行全新安装..."
fi

# 4. 准备安装环境 (备份配置)
log_info "停止服务并准备文件..."
systemctl stop "$SERVICE_NAME" 2>/dev/null

# !!! 关键步骤：升级时备份 config.yaml !!!
BACKUP_CONFIG="/tmp/easytier_config_backup.yaml"
rm -f "$BACKUP_CONFIG"

if [ -f "$CONFIG_PATH" ]; then
    log_info "检测到现有配置文件，正在备份..."
    cp "$CONFIG_PATH" "$BACKUP_CONFIG"
fi

# 清理安装目录
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 5. 下载与解压
TEMP_ZIP="/tmp/easytier_latest.zip"
log_info "正在下载: $REMOTE_VERSION_TAG ..."
curl -L -o "$TEMP_ZIP" "$DOWNLOAD_URL"

log_info "正在解压..."
unzip -q "$TEMP_ZIP" -d "$INSTALL_DIR"

# 处理解压后的目录结构
SUBDIR=$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -type d)
if [ -n "$SUBDIR" ]; then
    mv "$SUBDIR"/* "$INSTALL_DIR"/
    rmdir "$SUBDIR"
fi

rm -f "$TEMP_ZIP"
chmod +x "${INSTALL_DIR}/easytier-core"
chmod +x "${INSTALL_DIR}/easytier-cli" 2>/dev/null

if [ ! -f "${INSTALL_DIR}/easytier-core" ]; then
    log_error "安装失败: 未在解压目录找到 easytier-core 文件。"
fi

# 6. 配置文件处理 (还原备份 或 进入配置向导)
RESTORED_CONFIG=false

if [ -f "$BACKUP_CONFIG" ]; then
    log_info "正在还原配置文件..."
    mv "$BACKUP_CONFIG" "$CONFIG_PATH"
    RESTORED_CONFIG=true
    log_info "配置文件保留成功，跳过配置向导。"
fi

# 只有在没有还原配置（即全新安装）的情况下，才进入配置向导
if [ "$RESTORED_CONFIG" == "false" ]; then
    
    echo "========================================================"
    echo "检测到全新安装，请选择配置方式："
    echo " 1) 导入已有的 config.yaml 文件 (跳过手动设置)"
    echo " 2) 手动输入配置信息 (创建新节点)"
    echo "--------------------------------------------------------"
    read -p "请选择 (1/2) [默认: 2]: " config_choice
    config_choice=${config_choice:-2}

    USE_EXISTING_CONFIG="false"
    USER_CONFIG_PATH=""

    if [ "$config_choice" == "1" ]; then
        # --- 选项1：导入配置文件 ---
        while [ -z "$USER_CONFIG_PATH" ]; do
            read -p "请输入 config.yaml 的绝对路径: " input_path
            input_path=$(echo "$input_path" | tr -d '"' | tr -d "'")
            
            if [ -f "$input_path" ]; then
                USER_CONFIG_PATH="$input_path"
                USE_EXISTING_CONFIG="true"
                log_info "已选择配置文件: $USER_CONFIG_PATH"
            else
                echo -e "\033[31m错误：文件不存在，请重新输入。\033[0m"
            fi
        done
        
        cp "$USER_CONFIG_PATH" "$CONFIG_PATH"

    else
        # --- 选项2：手动配置 ---
        echo "--------------------------------------------------------"
        read -p "1. 请输入节点 Hostname (默认: $(hostname)): " input_hostname
        easyname=${input_hostname:-$(hostname)}

        while [ -z "$net_name" ]; do
            read -p "2. 请输入网络名称 (network_name): " net_name
            if [ -z "$net_name" ]; then echo -e "\033[31m   错误：网络名称不能为空\033[0m"; fi
        done

        while [ -z "$net_secret" ]; do
            read -p "3. 请输入网络密钥 (network_secret): " net_secret
            if [ -z "$net_secret" ]; then echo -e "\033[31m   错误：网络密钥不能为空\033[0m"; fi
        done

        echo -e "\n说明：Peer节点用于连接到公共节点或您的服务器。"
        read -p "4. 请输入 Peer 节点 URI (服务器可回车留空): " peer_uri

        echo -e "\n说明：默认开启 DHCP 自动分配 IP。如需手动指定 IPv4，请输入 n。"
        read -p "5. 是否开启 DHCP? (y/n) [默认: y]: " input_dhcp
        input_dhcp=${input_dhcp:-y}

        if [[ "$input_dhcp" == "y" || "$input_dhcp" == "Y" ]]; then
            use_dhcp="true"
            easyipv4=""
        else
            use_dhcp="false"
            while [ -z "$easyipv4" ]; do
                read -p "   请输入节点 IPv4 CIDR (例如 10.126.126.2/24): " easyipv4
            done
        fi

        # 生成 Config 内容
        INSTANCE_UUID=$(cat /proc/sys/kernel/random/uuid)
        log_info "生成配置文件..."

cat > "$CONFIG_PATH" <<EOF
hostname = "${easyname}"
instance_id = "${INSTANCE_UUID}"
dhcp = ${use_dhcp}
EOF
        if [ "$use_dhcp" == "false" ]; then
            echo "ipv4 = \"${easyipv4}\"" >> "$CONFIG_PATH"
        fi

cat >> "$CONFIG_PATH" <<EOF
listeners = [
    "tcp://0.0.0.0:11010",
    "udp://0.0.0.0:11010",
    "wg://0.0.0.0:11011",
]

[network_identity]
network_name = "${net_name}"
network_secret = "${net_secret}"

[flags]
private_mode = true
EOF

        if [ -n "$peer_uri" ]; then
cat >> "$CONFIG_PATH" <<EOF

[[peer]]
uri = "${peer_uri}"
EOF
        fi
    fi
fi

# 7. 设置 Systemd 服务 (无论升级还是安装都刷新一遍 Service 文件，以防万一)
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
log_info "刷新 Systemd 服务配置..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=EasyTier Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/easytier-core -c ./config.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务并验证
log_info "重载服务配置并启动..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

sleep 2

log_info "================ 服务状态检查 ================"
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "\033[32mEasyTier 服务运行中 (版本: ${REMOTE_VER_NUM})\033[0m"
    echo "------------------------------------------------"
    # 尝试获取 IP
    CURRENT_IP=$(${INSTALL_DIR}/easytier-cli ip 2>/dev/null)
    if [ -n "$CURRENT_IP" ]; then
        echo -e "当前 VPN IP: \033[36m${CURRENT_IP}\033[0m"
    fi
    echo "------------------------------------------------"
    if [ "$RESTORED_CONFIG" == "true" ]; then
        echo -e "\033[36m[升级成功] 已保留原有配置文件并升级到最新版。\033[0m"
    else
        echo -e "\033[36m[安装成功] 新节点已配置完成。\033[0m"
        echo "注意防火墙放行端口：TCP/UDP 11010, UDP 11011"
    fi
else
    echo -e "\033[31m服务启动失败！\033[0m"
    systemctl status "$SERVICE_NAME" --no-pager -l
    exit 1
fi
