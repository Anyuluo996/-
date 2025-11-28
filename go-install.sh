#!/bin/bash

# ==============================================================================
# Linux Go 安装脚本 (带代理选项)
# ------------------------------------------------------------------------------
# 脚本功能：
# 1. 询问用户是否设置代理。
# 2. 如果设置代理，使用 http://127.0.0.1:17890 作为代理。
# 3. 从 go.dev/dl 获取最新的 Go Linux AMD64 下载链接。
# 4. 删除 /usr/local/go 目录（如果存在），以清除之前的 Go 安装。
# 5. 下载并解压最新版本的 Go 到 /usr/local。
# 6. 配置 PATH 环境变量，将 /usr/local/go/bin 添加到其中。
# 7. 验证 Go 安装是否成功。
# 8. 如果之前设置了代理，安装完成后取消代理设置。
#
# 使用方法：
# chmod +x install_go.sh
# ./install_go.sh
#
# 注意：本脚本需要 sudo 权限来执行文件系统操作和配置系统范围的 PATH。
# ==============================================================================

# --- 配置 ---
# Go 安装目录
GO_INSTALL_DIR="/usr/local"
# Go 运行时目录（将在 GO_INSTALL_DIR 内创建）
GO_BIN_DIR="${GO_INSTALL_DIR}/go/bin"
# 默认代理地址
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

echo "--- 开始 Go 安装脚本 ---"

# --- 询问是否设置代理 ---
read -p "是否需要设置代理？(y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    USE_PROXY="yes"
    echo "将使用代理: $PROXY_URL"
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    PROXY_SET_FOR_SCRIPT=true
    # 对于 sudo 命令，需要显式传递代理变量（此脚本中curl不需要sudo，其他命令不需要代理）
else
    echo "不使用代理。"
fi

# --- 1. 获取最新的 Go Linux AMD64 下载链接 ---
echo "正在从 go.dev/dl 获取最新的 Go 下载链接..."

# 使用 curl 获取 go.dev/dl 页面内容，并通过 grep 和 sed 提取下载链接
# 查找 href="/dl/goX.Y.Z.linux-amd64.tar.gz" 这样的相对路径
GO_RELATIVE_PATH=$(curl -s "https://go.dev/dl/" | \
  grep -oP 'href="/dl/go\d+\.\d+(\.\d+)?\.linux-amd64\.tar\.gz"' | \
  head -n 1 | \
  sed -E 's/href="(\/dl\/go[0-9]+\.[0-9]+(\.[0-9]+)?\.linux-amd64\.tar\.gz)"/\1/')

if [ -z "$GO_RELATIVE_PATH" ]; then
    echo "错误：未能获取到 Go 下载链接。请检查网络连接或 go.dev 网站，或者go.dev页面结构可能已改变。"
    # 如果设置了代理，在此处取消
    if $PROXY_SET_FOR_SCRIPT; then
        echo "清理代理环境变量..."
        unset HTTP_PROXY
        unset HTTPS_PROXY
        # 恢复原始值，如果它们存在
        [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
        [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
    fi
    exit 1
fi

GO_DOWNLOAD_URL="https://go.dev${GO_RELATIVE_PATH}" # 拼接成完整 URL

GO_TAR_FILENAME=$(basename "$GO_DOWNLOAD_URL")
echo "获取到最新 Go 下载链接: $GO_DOWNLOAD_URL"
echo "文件名为: $GO_TAR_FILENAME"

# --- 2. 删除任何之前的 Go 安装 ---
echo "正在检查并删除旧的 Go 安装目录 ($GO_INSTALL_DIR/go)..."
if [ -d "${GO_INSTALL_DIR}/go" ]; then
    sudo rm -rf "${GO_INSTALL_DIR}/go"
    if [ $? -eq 0 ]; then
        echo "旧的 Go 安装已成功删除。"
    else
        echo "错误：无法删除旧的 Go 安装目录。请手动检查并删除：${GO_INSTALL_DIR}/go"
        # 如果设置了代理，在此处取消
        if $PROXY_SET_FOR_SCRIPT; then
            echo "清理代理环境变量..."
            unset HTTP_PROXY
            unset HTTPS_PROXY
            [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
            [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
        fi
        exit 1
    fi
else
    echo "未发现旧的 Go 安装目录，跳过删除。"
fi

# --- 3. 下载并解压 Go ---
echo "正在下载 $GO_TAR_FILENAME..."
TEMP_TAR_PATH="/tmp/$GO_TAR_FILENAME"

if ! curl -L -o "$TEMP_TAR_PATH" "$GO_DOWNLOAD_URL"; then
    echo "错误：下载 Go 压缩包失败。"
    rm -f "$TEMP_TAR_PATH"
    # 如果设置了代理，在此处取消
    if $PROXY_SET_FOR_SCRIPT; then
        echo "清理代理环境变量..."
        unset HTTP_PROXY
        unset HTTPS_PROXY
        [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
        [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
    fi
    exit 1
fi
echo "下载完成：$TEMP_TAR_PATH"

echo "正在解压 Go 压缩包到 $GO_INSTALL_DIR..."
if ! sudo tar -C "$GO_INSTALL_DIR" -xzf "$TEMP_TAR_PATH"; then
    echo "错误：解压 Go 压缩包失败。"
    rm -f "$TEMP_TAR_PATH"
    # 如果设置了代理，在此处取消
    if $PROXY_SET_FOR_SCRIPT; then
        echo "清理代理环境变量..."
        unset HTTP_PROXY
        unset HTTPS_PROXY
        [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
        [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
    fi
    exit 1
fi
echo "Go 已成功解压到 $GO_INSTALL_DIR/go。"

rm -f "$TEMP_TAR_PATH"

# --- 4. 添加 /usr/local/go/bin 到 PATH 环境变量 ---
echo "正在配置 PATH 环境变量..."

GO_PROFILE_PATH_FILE="/etc/profile.d/go.sh"

if [ ! -f "$GO_PROFILE_PATH_FILE" ] || ! grep -q "export PATH=.*${GO_BIN_DIR}" "$GO_PROFILE_PATH_FILE"; then
    echo "正在创建或更新 $GO_PROFILE_PATH_FILE 文件..."
    echo '#!/bin/sh' | sudo tee "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "export PATH=\$PATH:${GO_BIN_DIR}" | sudo tee -a "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "PATH 环境变量配置已写入 $GO_PROFILE_PATH_FILE。"
    echo "请注意：这些更改通常需要重新登录或运行 'source /etc/profile' 才能立即生效。"
else
    echo "$GO_PROFILE_PATH_FILE 已包含 Go PATH 配置，跳过。"
fi

# 立即在当前 shell 会话中应用 PATH 更改，以便后续 go version 检查
echo "立即在当前 shell 中应用 PATH 更改..."
export PATH=$PATH:${GO_BIN_DIR}

# --- 5. 验证 Go 安装 ---
echo "正在验证 Go 安装..."
if command -v go &>/dev/null; then
    echo "Go 已成功安装！"
    go version
else
    echo "错误：Go 命令未找到。请检查安装过程或 PATH 配置。"
    # 如果设置了代理，在此处取消
    if $PROXY_SET_FOR_SCRIPT; then
        echo "清理代理环境变量..."
        unset HTTP_PROXY
        unset HTTPS_PROXY
        [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
        [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
    fi
    exit 1
fi

# --- 6. 清理代理环境变量 ---
if $PROXY_SET_FOR_SCRIPT; then
    echo "安装完成，正在清理代理环境变量..."
    unset HTTP_PROXY
    unset HTTPS_PROXY
    # 恢复原始值，如果它们存在
    [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
    [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
    echo "代理环境变量已取消。"
fi
# --- 完成 ---
echo "--- Go 安装脚本完成 ---"
echo "✅ 安装成功！"
echo "⚠️  注意：为了在当前终端立即使用 go 命令，请执行以下命令："
echo "   source /etc/profile"
echo "   或者重新登录你的终端。"
