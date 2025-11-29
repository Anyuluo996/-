#!/bin/bash

# ==============================================================================
# Linux Go 自动更新/安装脚本
# ------------------------------------------------------------------------------
# 脚本功能：
# 1. 询问代理设置。
# 2. 获取 Go 最新版本信息。
# 3. 检查本地 Go 版本：
#    - 如果是最新版 -> 提示并退出。
#    - 如果版本旧或未安装 -> 继续。
# 4. 删除旧版本，下载并安装新版本。
# 5. 配置环境变量。
# ==============================================================================

# --- 配置 ---
GO_INSTALL_DIR="/usr/local"
GO_BIN_DIR="${GO_INSTALL_DIR}/go/bin"
PROXY_URL="http://127.0.0.1:17890"

# --- 变量初始化 ---
USE_PROXY="no"
ORIGINAL_HTTP_PROXY="$HTTP_PROXY"
ORIGINAL_HTTPS_PROXY="$HTTPS_PROXY"
PROXY_SET_FOR_SCRIPT=false

# --- 检查权限 ---
if [[ $EUID -ne 0 ]]; then
   echo "此脚本需要 root 权限执行。"
   echo "请使用 sudo 运行: sudo ./install_go.sh"
   exit 1
fi

echo "--- 开始 Go 安装/更新脚本 ---"

# --- 询问是否设置代理 ---
read -p "是否需要设置代理？(y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    USE_PROXY="yes"
    echo "将使用代理: $PROXY_URL"
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    PROXY_SET_FOR_SCRIPT=true
else
    echo "不使用代理。"
fi

# --- 1. 获取最新的 Go Linux AMD64 下载链接与版本号 ---
echo "正在从 go.dev/dl 获取最新的 Go 版本信息..."

# 抓取页面并提取 href
GO_RELATIVE_PATH=$(curl -s "https://go.dev/dl/" | \
  grep -oP 'href="/dl/go\d+\.\d+(\.\d+)?\.linux-amd64\.tar\.gz"' | \
  head -n 1 | \
  sed -E 's/href="(\/dl\/go[0-9]+\.[0-9]+(\.[0-9]+)?\.linux-amd64\.tar\.gz)"/\1/')

if [ -z "$GO_RELATIVE_PATH" ]; then
    echo "错误：未能获取到 Go 下载链接。请检查网络连接。"
    if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
    exit 1
fi

# 从链接中提取版本号，例如: /dl/go1.23.4.linux-amd64.tar.gz -> go1.23.4
LATEST_VERSION_TAG=$(echo "$GO_RELATIVE_PATH" | grep -oP 'go\d+\.\d+(\.\d+)?')
GO_DOWNLOAD_URL="https://go.dev${GO_RELATIVE_PATH}"

echo "检测到官方最新版本: $LATEST_VERSION_TAG"

# --- 2. 检查本地版本并对比 ---
if command -v go &>/dev/null; then
    # 获取本地版本，例如 "go version go1.21.5 linux/amd64" -> "go1.21.5"
    CURRENT_VERSION_TAG=$(go version | awk '{print $3}')
    echo "当前本地安装版本: $CURRENT_VERSION_TAG"

    if [[ "$CURRENT_VERSION_TAG" == "$LATEST_VERSION_TAG" ]]; then
        echo "=========================================="
        echo "✅ 当前已是最新版本 ($CURRENT_VERSION_TAG)，无需重新安装。"
        echo "=========================================="
        # 清理代理设置并退出
        if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
        exit 0
    else
        echo "⚠️  发现新版本 ($CURRENT_VERSION_TAG -> $LATEST_VERSION_TAG)，准备进行升级..."
    fi
else
    echo "未检测到 Go 环境，准备开始安装 $LATEST_VERSION_TAG..."
fi

# ============================================================
# 下面开始执行安装流程 (卸载旧版 -> 下载 -> 解压)
# ============================================================

GO_TAR_FILENAME=$(basename "$GO_DOWNLOAD_URL")
echo "下载地址: $GO_DOWNLOAD_URL"

# --- 3. 删除任何之前的 Go 安装 ---
echo "正在检查并删除旧的 Go 安装目录 ($GO_INSTALL_DIR/go)..."
if [ -d "${GO_INSTALL_DIR}/go" ]; then
    sudo rm -rf "${GO_INSTALL_DIR}/go"
    if [ $? -eq 0 ]; then
        echo "旧的 Go 安装已删除。"
    else
        echo "错误：无法删除旧目录 ${GO_INSTALL_DIR}/go"
        if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
        exit 1
    fi
else
    echo "未发现旧目录，跳过删除。"
fi

# --- 4. 下载并解压 Go ---
echo "正在下载 $GO_TAR_FILENAME..."
TEMP_TAR_PATH="/tmp/$GO_TAR_FILENAME"

if ! curl -L -o "$TEMP_TAR_PATH" "$GO_DOWNLOAD_URL"; then
    echo "错误：下载失败。"
    rm -f "$TEMP_TAR_PATH"
    if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
    exit 1
fi

echo "正在解压到 $GO_INSTALL_DIR..."
if ! sudo tar -C "$GO_INSTALL_DIR" -xzf "$TEMP_TAR_PATH"; then
    echo "错误：解压失败。"
    rm -f "$TEMP_TAR_PATH"
    if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
    exit 1
fi
rm -f "$TEMP_TAR_PATH"
echo "解压完成。"

# --- 5. 配置 PATH 环境变量 ---
echo "正在配置 PATH..."
GO_PROFILE_PATH_FILE="/etc/profile.d/go.sh"

if [ ! -f "$GO_PROFILE_PATH_FILE" ] || ! grep -q "export PATH=.*${GO_BIN_DIR}" "$GO_PROFILE_PATH_FILE"; then
    echo '#!/bin/sh' | sudo tee "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "export PATH=\$PATH:${GO_BIN_DIR}" | sudo tee -a "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "PATH 配置已写入 $GO_PROFILE_PATH_FILE"
else
    echo "PATH 配置已存在，跳过。"
fi

# 临时应用 PATH 以便验证
export PATH=$PATH:${GO_BIN_DIR}

# --- 6. 验证 ---
echo "正在验证安装..."
if command -v go &>/dev/null; then
    NEW_VERSION=$(go version)
    echo "✅ Go 安装/升级成功！"
    echo "当前版本: $NEW_VERSION"
else
    echo "❌ 错误：安装后无法找到 go 命令。"
    if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
    exit 1
fi

# --- 7. 清理代理 ---
if $PROXY_SET_FOR_SCRIPT; then
    unset HTTP_PROXY
    unset HTTPS_PROXY
    [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
    [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
    echo "代理环境变量已取消。"
fi

echo "--- 脚本执行结束 ---"
echo "提示：请执行 'source /etc/profile' 刷新环境变量。"
