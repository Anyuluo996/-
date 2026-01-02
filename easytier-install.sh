#!/bin/bash

INSTALL_DIR="/usr/local/bin/easytier"
SERVICE_NAME="easytier.service"
GITHUB_REPO="EasyTier/EasyTier"

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
for cmd in curl unzip jq; do
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

# 2. 获取最新版本下载链接
log_info "正在查询 GitHub 最新版本..."
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
DOWNLOAD_URL=$(curl -s "$API_URL" | jq -r '.assets[] | select(.name | test("easytier-linux-x86_64-v.*\\.zip$")) | .browser_download_url')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    log_error "无法获取下载链接，请检查网络或 GitHub API 限制。"
fi

log_info "获取成功: $DOWNLOAD_URL"

# 3. 用户交互配置 (导入文件 OR 手动设置)
echo "========================================================"
echo "配置方式选择："
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
        # 去除可能存在的引号
        input_path=$(echo "$input_path" | tr -d '"' | tr -d "'")
        
        if [ -f "$input_path" ]; then
            USER_CONFIG_PATH="$input_path"
            USE_EXISTING_CONFIG="true"
            log_info "已选择配置文件: $USER_CONFIG_PATH"
        else
            echo -e "\033[31m错误：文件不存在，请重新输入。\033[0m"
        fi
    done

else
    # --- 选项2：手动配置 (原有逻辑) ---
    echo "--------------------------------------------------------"
    # 3.1 Hostname
    read -p "1. 请输入节点 Hostname (默认: $(hostname)): " input_hostname
    easyname=${input_hostname:-$(hostname)}

    # 3.2 网络名称 (必填)
    while [ -z "$net_name" ]; do
        read -p "2. 请输入网络名称 (network_name): " net_name
        if [ -z "$net_name" ]; then echo -e "\033[31m   错误：网络名称不能为空\033[0m"; fi
    done

    # 3.3 网络密钥 (必填)
    while [ -z "$net_secret" ]; do
        read -p "3. 请输入网络密钥 (network_secret): " net_secret
        if [ -z "$net_secret" ]; then echo -e "\033[31m   错误：网络密钥不能为空\033[0m"; fi
    done

    # 3.4 Peer 节点配置 (选填)
    echo -e "\n说明：Peer节点用于连接到公共节点或您的服务器。"
    echo "      如果您本机作为核心服务器/根节点，请直接回车留空。"
    read -p "4. 请输入 Peer 节点 URI: " peer_uri

    if [ -z "$peer_uri" ]; then
        echo "   -> 模式: 服务器/根节点 (无上级 Peer)"
    else
        echo "   -> 模式: 客户端/子节点 (连接到 $peer_uri)"
    fi

    # 3.5 IP/DHCP 设置
    echo -e "\n说明：默认开启 DHCP 自动分配 IP。如需手动指定 IPv4，请输入 n。"
    read -p "5. 是否开启 DHCP? (y/n) [默认: y]: " input_dhcp
    input_dhcp=${input_dhcp:-y}

    if [[ "$input_dhcp" == "y" || "$input_dhcp" == "Y" ]]; then
        use_dhcp="true"
        easyipv4=""
        echo "   -> DHCP 已开启"
    else
        use_dhcp="false"
        while [ -z "$easyipv4" ]; do
            read -p "   请输入节点 IPv4 CIDR (例如 10.126.126.2/24): " easyipv4
        done
    fi
fi
echo "========================================================"

# 4. 下载与安装
log_info "准备安装目录: ${INSTALL_DIR}"
systemctl stop "$SERVICE_NAME" 2>/dev/null
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

TEMP_ZIP="/tmp/easytier_latest.zip"
log_info "正在下载..."
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

# 5. 生成或复制配置文件
CONFIG_PATH="${INSTALL_DIR}/config.yaml"

if [ "$USE_EXISTING_CONFIG" == "true" ]; then
    # --- 分支A：复制已有配置 ---
    log_info "正在导入配置文件..."
    cp "$USER_CONFIG_PATH" "$CONFIG_PATH"
    if [ $? -eq 0 ]; then
        log_info "配置文件导入成功！"
    else
        log_error "复制配置文件失败，请检查文件权限。"
    fi
else
    # --- 分支B：生成新配置 ---
    INSTANCE_UUID=$(cat /proc/sys/kernel/random/uuid)
    log_info "生成配置文件: ${CONFIG_PATH}"

    # 写入第一部分配置
cat > "$CONFIG_PATH" <<EOF
hostname = "${easyname}"
instance_id = "${INSTANCE_UUID}"
dhcp = ${use_dhcp}
EOF

    # 如果 DHCP 关闭，写入 ipv4
    if [ "$use_dhcp" == "false" ]; then
        echo "ipv4 = \"${easyipv4}\"" >> "$CONFIG_PATH"
    fi

    # 写入公共配置部分
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

    # 如果用户输入了 Peer，写入 Peer 配置
    if [ -n "$peer_uri" ]; then
cat >> "$CONFIG_PATH" <<EOF

[[peer]]
uri = "${peer_uri}"
EOF
    fi
fi

# 6. 设置 Systemd 服务
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
log_info "配置 Systemd 服务..."

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

# 7. 启动服务并验证
log_info "重载服务配置并启动..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

sleep 2

log_info "================ 服务状态检查 ================"
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "\033[32mEasyTier 服务启动成功 (Active: active)\033[0m"
    echo "------------------------------------------------"
    # 尝试获取当前虚拟IP
    CURRENT_IP=$(${INSTALL_DIR}/easytier-cli ip 2>/dev/null)
    if [ -n "$CURRENT_IP" ]; then
        echo -e "当前 VPN IP: \033[36m${CURRENT_IP}\033[0m"
    fi
    echo "------------------------------------------------"
    echo -e "\033[33m[注意] 请确保防火墙放行以下端口：\033[0m"
    echo -e "  - TCP/UDP: 11010"
    echo -e "  - UDP: 11011 (WireGuard)"
    echo "------------------------------------------------"
else
    echo -e "\033[31mEasyTier 服务启动失败！请检查日志：\033[0m"
    systemctl status "$SERVICE_NAME" --no-pager -l
    exit 1
fi
log_info "安装脚本运行结束。"
