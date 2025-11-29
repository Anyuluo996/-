#!/bin/bash

# ==============================================================================
# Derper 自动安装脚本 (支持 PEM 格式证书版)
# ==============================================================================

# --- 检查 Root 权限 ---
if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本需要 root 权限执行。"
   exit 1
fi

echo "--- 开始 Derper 安装流程 ---"

# ------------------------------------------------------------------------------
# 1. 环境与版本检查
# ------------------------------------------------------------------------------
echo "Step 1: 检查 Go 环境..."

install_go_prompt() {
    echo "========================================================"
    echo "错误：Go 环境缺失或版本过低。"
    echo "请执行以下命令安装最新版 Go："
    echo ""
    echo "bash <(curl -sL https://xget.anyul.cn/gh/Anyuluo996/-/raw/refs/heads/main/go-install.sh)"
    echo ""
    echo "安装完成后，请重新运行此脚本。"
    echo "========================================================"
    exit 1
}

if ! command -v go &> /dev/null; then
    install_go_prompt
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
# 3. 安装 Derper (带版本错误捕获)
# ------------------------------------------------------------------------------
echo "Step 2: 正在安装 Derper..."

# 捕获错误输出
INSTALL_OUTPUT=$(go install -v tailscale.com/cmd/derper@latest 2>&1 | tee /dev/tty)
INSTALL_EXIT_CODE=${PIPESTATUS[0]}

if [ $INSTALL_EXIT_CODE -ne 0 ]; then
    echo "❌ 安装失败。"
    if echo "$INSTALL_OUTPUT" | grep -q -E "invalid go version|must match format"; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "【关键错误】：当前 Go 版本过低，无法编译最新版 Derper。"
        echo "请务必先升级 Go 环境！"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        install_go_prompt
    fi
    exit 1
else
    echo "✅ Derper 安装成功！"
fi

# 查找二进制文件路径
DERPER_BIN=$(which derper)
if [ -z "$DERPER_BIN" ]; then
    GOPATH=$(go env GOPATH)
    DERPER_BIN="$GOPATH/bin/derper"
    [ ! -f "$DERPER_BIN" ] && DERPER_BIN="/root/go/bin/derper"
fi

# ------------------------------------------------------------------------------
# 4. 配置参数收集
# ------------------------------------------------------------------------------
echo "Step 3: 配置服务参数"

DEFAULT_ADDR=":8888"
DEFAULT_STUN="8889"
DEFAULT_CERT_DIR="/root/cerdit"

read -p "请输入监听端口 [默认 :8888]: " INPUT_ADDR
ADDR=${INPUT_ADDR:-$DEFAULT_ADDR}

read -p "请输入 STUN 端口 [默认 8889]: " INPUT_STUN
STUN=${INPUT_STUN:-$DEFAULT_STUN}

while [[ -z "$HOSTNAME" ]]; do
    read -p "请输入 Hostname (例如 derp.mysite.com): " HOSTNAME
done

# ------------------------------------------------------------------------------
# 5. 证书与密钥处理逻辑 (已更新提示支持 PEM)
# ------------------------------------------------------------------------------
echo "Step 4: 证书配置"
read -p "是否要提供现有的 SSL 证书和密钥？(y/N) " -n 1 -r
echo

CERT_MODE="letsencrypt"
CERT_DIR_FINAL=$DEFAULT_CERT_DIR

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # --- 用户选择提供证书 ---
    CERT_MODE="manual"
    
    read -p "请输入证书安装目录 [默认 $DEFAULT_CERT_DIR]: " INPUT_DIR
    CERT_DIR_FINAL=${INPUT_DIR:-$DEFAULT_CERT_DIR}
    
    # 这里的提示语已更新，明确支持 .pem
    echo "注意：源文件后缀即使是 .pem 也可以，脚本会自动重命名为 derper 需要的格式。"
    read -p "请输入证书文件路径 (.crt / .pem): " SRC_CRT
    read -p "请输入密钥文件路径 (.key / .pem): " SRC_KEY
    
    if [[ ! -f "$SRC_CRT" ]] || [[ ! -f "$SRC_KEY" ]]; then
        echo "错误：找不到指定的证书或密钥文件，请检查路径。"
        exit 1
    fi
    
    echo "正在创建目录: $CERT_DIR_FINAL"
    mkdir -p "$CERT_DIR_FINAL"
    
    # 强制重命名为 hostname.crt 和 hostname.key (Derper 硬性要求)
    DEST_CRT="$CERT_DIR_FINAL/$HOSTNAME.crt"
    DEST_KEY="$CERT_DIR_FINAL/$HOSTNAME.key"
    
    echo "正在处理证书文件..."
    cp "$SRC_CRT" "$DEST_CRT"
    cp "$SRC_KEY" "$DEST_KEY"
    
    echo "✅ 证书已就绪 (已重命名以适配 Derper):"
    echo "  $DEST_CRT"
    echo "  $DEST_KEY"

else
    # --- 用户不提供证书 ---
    echo "未选择自定义证书，将使用 Let's Encrypt 模式。"
    echo "证书目录路径将设置为: $CERT_DIR_FINAL"
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
    -hostname ${HOSTNAME} \\
    --certmode ${CERT_MODE} \\
    -certdir ${CERT_DIR_FINAL} \\
    --verify-clients
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo "========================================================"
echo "✅ 安装配置完成！"
echo "--------------------------------------------------------"
echo "  Systemd Service: derper.service"
echo "  证书模式: $CERT_MODE"
echo "  主机名:   $HOSTNAME"
echo "--------------------------------------------------------"
echo "启动命令："
echo "  systemctl start derper.service"
echo "  systemctl enable derper.service"
echo "========================================================"
