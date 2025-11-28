#!/bin/bash

# ==============================================================================
# Derper 自动安装与配置脚本
# ------------------------------------------------------------------------------
# 功能：
# 1. 检查 Go 环境，不存在则提示安装并退出。
# 2. 询问是否设置 Go 代理。
# 3. 编译安装 derper。
# 4. 交互式获取端口、域名、证书路径等配置。
# 5. 生成 systemd 配置文件。
# ==============================================================================

# --- 检查是否以 root 运行 ---
if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本需要 root 权限执行以配置 systemd 服务。"
   echo "请使用 sudo 运行此脚本。"
   exit 1
fi

echo "--- 开始 Derper 安装流程 ---"

# --- 1. 检查 Go 环境 ---
echo "正在检查 Go 环境..."
if ! command -v go &> /dev/null; then
    echo "========================================================"
    echo "错误：未检测到 Go 环境。"
    echo "请执行以下命令进行安装："
    echo ""
    echo "bash <(curl -sL https://xget.anyul.cn/gh/Anyuluo996/-/raw/refs/heads/main/go-install.sh)"
    echo ""
    echo "安装完成后，请重新运行此脚本。"
    echo "========================================================"
    exit 1
fi
echo "检测到 Go 已安装: $(go version)"

# --- 2. 设置 Go 代理 ---
read -p "是否需要设置 Go 代理 (https://xget.anyul.cn/golang)？(y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "正在设置 GOPROXY..."
    export GOPROXY=https://xget.anyul.cn/golang,direct
    echo "GOPROXY 已设置为: $GOPROXY"
else
    echo "跳过代理设置。"
fi

# --- 3. 安装 Derper ---
echo "正在安装 Derper (tailscale.com/cmd/derper@latest)..."
if go install tailscale.com/cmd/derper@latest; then
    echo "Derper 安装成功！"
else
    echo "Derper 安装失败，请检查网络或 Go 环境。"
    exit 1
fi

# 确定安装路径 (默认为 /root/go/bin/derper，符合你的 Service 模板)
DERPER_BIN="/root/go/bin/derper"
if [ ! -f "$DERPER_BIN" ]; then
    # 尝试查找实际路径
    GOPATH=$(go env GOPATH)
    if [ -f "$GOPATH/bin/derper" ]; then
        DERPER_BIN="$GOPATH/bin/derper"
    else
        echo "警告：无法在默认路径找到 derper 二进制文件，Systemd 配置可能需要手动调整。"
    fi
fi
echo "Derper 二进制路径: $DERPER_BIN"

# --- 4. 获取用户配置输入 ---
echo "--- 配置 Derper 服务参数 ---"

# 默认值
DEFAULT_ADDR=":8888"
DEFAULT_STUN="8889"
DEFAULT_DIR="/root/cerdit"

read -p "请输入监听端口 (默认为 :8888): " INPUT_ADDR
ADDR=${INPUT_ADDR:-$DEFAULT_ADDR}

read -p "请输入 STUN 端口 (默认为 8889): " INPUT_STUN
STUN=${INPUT_STUN:-$DEFAULT_STUN}

read -p "请输入 Hostname/IP (例如 223.109.49.110): " HOSTNAME
if [ -z "$HOSTNAME" ]; then
    echo "错误：Hostname 不能为空！"
    exit 1
fi

read -p "请输入证书存放目录 (默认为 /root/cerdit): " INPUT_CERT
CERT_DIR=${INPUT_CERT:-$DEFAULT_DIR}

# 确保证书目录存在
if [ ! -d "$CERT_DIR" ]; then
    echo "目录 $CERT_DIR 不存在，正在创建..."
    mkdir -p "$CERT_DIR"
fi

# --- 5. 生成 Systemd 服务文件 ---
SERVICE_FILE="/etc/systemd/system/derper.service"

echo "正在生成服务文件: $SERVICE_FILE ..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tailscale derp service
After=network.target

[Service]
# 注意：如果你不是 root 用户，ExecStart 的路径可能需要修改
ExecStart=${DERPER_BIN} \\
    -c derper \\
    -a ${ADDR} -http-port -1 \\
    -stun-port ${STUN} \\
    -hostname ${HOSTNAME} \\
    --certmode manual \\
    -certdir ${CERT_DIR} \\
    --verify-clients
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 重载 systemd 配置
systemctl daemon-reload

echo "========================================================"
echo "✅ Derper 安装与配置完成！"
echo "服务名称: derper.service"
echo "配置文件: $SERVICE_FILE"
echo ""
echo "请执行以下命令启动并设置开机自启："
echo ""
echo "systemctl start derper.service"
echo "systemctl enable derper.service"
echo "========================================================"