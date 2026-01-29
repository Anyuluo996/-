#!/bin/bash

# ==============================================================================
# Derper 自动安装脚本 
# 特性：自动安装Go / 自动获取IP / 自动生成10年自签证书 / SSL支持
# ==============================================================================

# --- 检查 Root 权限 ---
if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本需要 root 权限执行。"
   exit 1
fi

echo "--- 开始 Derper 安装流程 ---"

# ==============================================================================
# 函数定义：自动安装 Go
# ==============================================================================
function auto_install_go() {
    echo "========================================================"
    echo "⚠️ 检测到 Go 环境缺失或版本过低"
    echo "⏳ 正在自动执行 Go 安装脚本..."
    echo "========================================================"
    
    bash <(curl -sL https://xget.anyul.cn/gh/Anyuluo996/-/raw/refs/heads/main/go-install.sh)
    
    if [ $? -ne 0 ]; then
        echo "❌ Go 安装脚本执行失败，请检查网络。"
        exit 1
    fi
    
    # 刷新环境变量，确保当前 Shell 能找到 go 命令
    echo "🔄 正在刷新环境变量..."
    [ -f /etc/profile ] && source /etc/profile
    [ -f "$HOME/.profile" ] && source "$HOME/.profile"
    [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
    
    # 强制添加常见 Go 路径，防止 source 不生效
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
    
    if ! command -v go &> /dev/null; then
        echo "❌ 无法调用 Go 命令。请尝试断开 SSH 后重新连接并运行脚本。"
        exit 1
    fi
    
    echo "✅ Go 环境已就绪: $(go version)"
}

# ------------------------------------------------------------------------------
# 1. 环境检查与 Go 安装
# ------------------------------------------------------------------------------
echo "Step 1: 检查 Go 环境..."

if ! command -v go &> /dev/null; then
    auto_install_go
fi

# 检查 OpenSSL (生成证书必须)
if ! command -v openssl &> /dev/null; then
    echo "正在安装 OpenSSL..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y openssl
    elif [ -f /etc/redhat-release ]; then
        yum install -y openssl
    fi
fi

# ------------------------------------------------------------------------------
# 2. 代理设置
# ------------------------------------------------------------------------------
read -p "是否需要设置 Go 代理 (https://xget.anyul.cn/golang)？(y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    export GOPROXY=https://xget.anyul.cn/golang,direct
    export GOSUMDB=off
    echo "代理已设置 (GOSUMDB=off)"
fi

# ------------------------------------------------------------------------------
# 3. 安装 Derper (带自动重试机制)
# ------------------------------------------------------------------------------
echo "Step 2: 正在安装 Derper..."

install_derper() {
    go install -v tailscale.com/cmd/derper@latest
}

# 尝试安装
if ! install_derper; then
    echo "⚠️ 安装遭遇错误，正在分析原因..."
    
    # 再次尝试捕获输出判断是否因为版本过低
    ERR_OUTPUT=$(go install -v tailscale.com/cmd/derper@latest 2>&1)
    
    if echo "$ERR_OUTPUT" | grep -q -E "invalid go version|must match format"; then
        echo "🚨 检测到 Go 版本过低，无法编译最新版 Derper。"
        
        # 自动升级 Go
        auto_install_go
        
        echo "🔄 Go 升级完成，重新尝试安装 Derper..."
        if ! install_derper; then
            echo "❌ 重试安装失败。请检查网络或手动解决错误。"
            exit 1
        fi
    else
        echo "❌ 安装失败，错误详情："
        echo "$ERR_OUTPUT"
        exit 1
    fi
fi

echo "✅ Derper 安装成功！"

# 查找二进制文件路径
DERPER_BIN=$(which derper)
if [ -z "$DERPER_BIN" ]; then
    GOPATH=$(go env GOPATH)
    DERPER_BIN="$GOPATH/bin/derper"
    [ ! -f "$DERPER_BIN" ] && DERPER_BIN="/root/go/bin/derper"
fi

# ------------------------------------------------------------------------------
# 4. 配置参数收集 (自动 IP 逻辑)
# ------------------------------------------------------------------------------
echo "Step 3: 配置服务参数"

DEFAULT_ADDR=":8888"
DEFAULT_STUN="8889"
DEFAULT_CERT_DIR="/root/cerdit"

read -p "请输入监听端口 [默认 :8888]: " INPUT_ADDR
ADDR=${INPUT_ADDR:-$DEFAULT_ADDR}

read -p "请输入 STUN 端口 [默认 8889]: " INPUT_STUN
STUN=${INPUT_STUN:-$DEFAULT_STUN}

# 自动获取 IP 逻辑
read -p "请输入 Hostname/IP (留空则自动获取公网IP): " INPUT_HOST
if [ -z "$INPUT_HOST" ]; then
    echo "检测到输入为空，正在通过 ip.agi.li 获取公网 IP..."
    DERP_HOST=$(curl -s https://ip.agi.li)
    if [ -z "$DERP_HOST" ]; then
        echo "错误：无法自动获取 IP，请检查网络或手动输入。"
        exit 1
    fi
    echo "✅ 已获取公网 IP: ${DERP_HOST}"
else
    DERP_HOST=$INPUT_HOST
fi

# ------------------------------------------------------------------------------
# 5. 证书与密钥处理逻辑 (支持 PEM 或 自动生成自签证书)
# ------------------------------------------------------------------------------
echo "Step 4: 证书配置"
read -p "是否要提供现有的 SSL 证书和密钥？(y/N) [选 N 则自动生成10年自签证书]: " -n 1 -r
echo

# 默认全部走 manual 模式
CERT_MODE="manual"
read -p "请输入证书安装目录 [默认 $DEFAULT_CERT_DIR]: " INPUT_DIR
CERT_DIR_FINAL=${INPUT_DIR:-$DEFAULT_CERT_DIR}
mkdir -p "$CERT_DIR_FINAL"

DEST_CRT="$CERT_DIR_FINAL/$DERP_HOST.crt"
DEST_KEY="$CERT_DIR_FINAL/$DERP_HOST.key"

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # --- 用户选择提供现有证书 ---
    echo "注意：源文件后缀即使是 .pem 也可以，脚本会自动重命名为 derper 需要的格式。"
    read -p "请输入证书文件路径 (.crt / .pem): " SRC_CRT
    read -p "请输入密钥文件路径 (.key / .pem): " SRC_KEY
    
    if [[ ! -f "$SRC_CRT" ]] || [[ ! -f "$SRC_KEY" ]]; then
        echo "错误：找不到指定的证书或密钥文件，请检查路径。"
        exit 1
    fi
    
    echo "正在复制证书文件..."
    cp "$SRC_CRT" "$DEST_CRT"
    cp "$SRC_KEY" "$DEST_KEY"
    echo "✅ 现有证书已部署。"

else
    # --- 用户不提供证书 -> 自动生成自签证书 ---
    echo "正在生成自签名证书 (有效期 10 年)..."
    echo "Host/IP: $DERP_HOST"
    
    # 判断是否为 IP 地址以调整 SAN 字段
    if [[ "$DERP_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        SAN_EXT="subjectAltName=IP:${DERP_HOST}"
    else
        SAN_EXT="subjectAltName=DNS:${DERP_HOST}"
    fi
    
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$DEST_KEY" \
        -out "$DEST_CRT" \
        -subj "/CN=${DERP_HOST}" \
        -addext "$SAN_EXT"
        
    if [ $? -eq 0 ]; then
        echo "✅ 自签证书生成成功！"
        echo "   Cert: $DEST_CRT"
        echo "   Key:  $DEST_KEY"
    else
        echo "❌ 证书生成失败，请检查 OpenSSL 是否安装。"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 6. 生成 Systemd 服务
# ------------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/derper.service"
echo "Step 5: 生成 Systemd 服务文件 -> $SERVICE_FILE"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tailscale derp service
After=network.target

[Service]
ExecStart=${DERPER_BIN} \\
    -c derper \\
    -a ${ADDR} -http-port -1 \\
    -stun-port ${STUN} \\
    -hostname ${DERP_HOST} \\
    --certmode ${CERT_MODE} \\
    -certdir ${CERT_DIR_FINAL} \\
    --verify-clients
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ------------------------------------------------------------------------------
# 7. 启动服务
# ------------------------------------------------------------------------------
echo "Step 6: 正在启动并开机自启服务..."
systemctl enable derper.service
systemctl start derper.service

echo "========================================================"
echo "✅ 安装配置完成！服务已启动。"
echo "--------------------------------------------------------"
echo "  Systemd Service: derper.service"
echo "  主机/IP:  $DERP_HOST"
echo "  证书目录: $CERT_DIR_FINAL"
echo "--------------------------------------------------------"
echo "当前服务状态："
systemctl status derper.service --no-pager | grep "Active:"
echo "========================================================"
