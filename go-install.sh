#!/bin/bash

# ==============================================================================
# Linux Go 自动更新/安装脚本 (全链路加速 & 智能重试版)
# ==============================================================================

# --- 基础配置 ---
GO_INSTALL_DIR="/usr/local"
GO_BIN_DIR="${GO_INSTALL_DIR}/go/bin"

# 默认值设置
DEFAULT_PROXY="http://127.0.0.1:17890"
DEFAULT_ACCEL_PREFIX="https://steamproxy.9965421.xyz/"
GO_OFFICIAL_DL_PAGE="https://go.dev/dl/"

# --- 变量初始化 ---
USE_PROXY="no"
ORIGINAL_HTTP_PROXY="$HTTP_PROXY"
ORIGINAL_HTTPS_PROXY="$HTTPS_PROXY"
PROXY_SET_FOR_SCRIPT=false
ACCEL_PREFIX=""

# --- 检查权限 ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ 此脚本需要 root 权限执行。"
   exit 1
fi

echo "--- 开始 Go 安装/更新脚本 ---"

# --- 辅助函数：应用代理环境变量 ---
apply_proxy() {
    local proxy_url=$1
    if [ -n "$proxy_url" ]; then
        export HTTP_PROXY="$proxy_url"
        export HTTPS_PROXY="$proxy_url"
        PROXY_SET_FOR_SCRIPT=true
        USE_PROXY="yes"
        # 如果启用代理，逻辑上禁用加速前缀，防止冲突或双重代理
        ACCEL_PREFIX="" 
        echo "🌐 已启用代理: $proxy_url"
    fi
}

# --- 辅助函数：清除代理环境变量 ---
clear_proxy() {
    if $PROXY_SET_FOR_SCRIPT; then
        unset HTTP_PROXY
        unset HTTPS_PROXY
        [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
        [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
        PROXY_SET_FOR_SCRIPT=false
        USE_PROXY="no"
        echo "🌐 已清除脚本设置的代理"
    fi
}

# --- 辅助函数：获取下载链接解析 ---
# 参数 $1: 目标 URL
fetch_go_path_from_url() {
    local target_url=$1
    # -s: 静默模式, -L: 跟随跳转, --connect-timeout: 设短一点以便快速失败重试
    curl -s -L --connect-timeout 8 "$target_url" | \
    grep -oP 'href="/dl/go\d+\.\d+(\.\d+)?\.linux-amd64\.tar\.gz"' | \
    head -n 1 | \
    sed -E 's/href="(\/dl\/go[0-9]+\.[0-9]+(\.[0-9]+)?\.linux-amd64\.tar\.gz)"/\1/'
}

# --- 辅助函数：智能卸载 ---
uninstall_old_go() {
    echo "正在检测旧版本..."
    CURRENT_GO_PATH=$(command -v go)
    if [[ -z "$CURRENT_GO_PATH" ]]; then
        rm -rf "${GO_INSTALL_DIR}/go"
        return
    fi
    echo "发现旧版本: $CURRENT_GO_PATH"
    if [[ "$CURRENT_GO_PATH" == *"/usr/local/go"* ]]; then
        rm -rf "${GO_INSTALL_DIR}/go"
        return
    fi
    if [[ "$CURRENT_GO_PATH" == *"/usr/bin/go"* ]] || [[ "$CURRENT_GO_PATH" == *"/bin/go"* ]]; then
        echo "⚠️  检测为包管理器安装版本，尝试卸载..."
        if [ -f /etc/os-release ]; then . /etc/os-release; else rm -rf "${GO_INSTALL_DIR}/go"; return; fi
        case "$ID" in
            ubuntu|debian|kali|linuxmint) apt-get remove -y golang-go golang && apt-get autoremove -y ;;
            centos|rhel|fedora|rocky) if command -v dnf &> /dev/null; then dnf remove -y golang; else yum remove -y golang; fi ;;
            arch|manjaro) pacman -Rs --noconfirm go ;;
            alpine) apk del go ;;
            *) echo "建议后续手动检查卸载情况。" ;;
        esac
    fi
    if [ -d "${GO_INSTALL_DIR}/go" ]; then rm -rf "${GO_INSTALL_DIR}/go"; fi
}

# ==============================================================================
# 阶段 1: 初始配置交互
# ==============================================================================

echo "----------------------------------------------------"
read -p "初始设置：是否使用代理？(y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "请输入代理地址 (默认: $DEFAULT_PROXY): " INPUT_PROXY
    apply_proxy "${INPUT_PROXY:-$DEFAULT_PROXY}"
else
    read -p "是否设置下载加速链接 (SteamProxy/GitHub加速等)? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then # 默认为 Yes
        read -p "请输入加速前缀 (默认: $DEFAULT_ACCEL_PREFIX): " INPUT_ACCEL
        ACCEL_PREFIX=${INPUT_ACCEL:-$DEFAULT_ACCEL_PREFIX}
        echo "🚀 模式已设定: 全链路加速 (前缀: $ACCEL_PREFIX)"
    fi
fi
echo "----------------------------------------------------"

# ==============================================================================
# 阶段 2: 获取版本信息 (包含失败重试与回退逻辑)
# ==============================================================================

echo "🔍 正在获取最新的 Go 版本信息..."
GO_RELATIVE_PATH=""
VERSION_FETCH_SUCCESS=false

# --- 步骤 2.1: 尝试使用加速链接 (如果配置了) ---
if [[ "$USE_PROXY" == "no" && -n "$ACCEL_PREFIX" ]]; then
    # 构造：加速前缀 + 官方网页地址
    ACCEL_PAGE_URL="${ACCEL_PREFIX}${GO_OFFICIAL_DL_PAGE}"
    echo "   尝试从加速镜像获取: $ACCEL_PAGE_URL"
    GO_RELATIVE_PATH=$(fetch_go_path_from_url "$ACCEL_PAGE_URL")
    
    if [ -n "$GO_RELATIVE_PATH" ]; then
        VERSION_FETCH_SUCCESS=true
        echo "   ✅ 获取成功。"
    else
        echo "   ⚠️  加速镜像连接失败，回退到官方源..."
    fi
fi

# --- 步骤 2.2: 尝试使用官方链接 (直连或现有代理) ---
if [ "$VERSION_FETCH_SUCCESS" = false ]; then
    echo "   尝试直接访问: $GO_OFFICIAL_DL_PAGE"
    GO_RELATIVE_PATH=$(fetch_go_path_from_url "$GO_OFFICIAL_DL_PAGE")
    
    if [ -n "$GO_RELATIVE_PATH" ]; then
        VERSION_FETCH_SUCCESS=true
        echo "   ✅ 获取成功。"
    fi
fi

# --- 步骤 2.3: 失败后询问代理 (二次救援) ---
if [ "$VERSION_FETCH_SUCCESS" = false ]; then
    echo "❌ 错误：无法获取 Go 版本列表。"
    echo "----------------------------------------------------"
    read -p "获取版本失败。是否现在配置代理重试？(y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "请输入代理地址 (默认: $DEFAULT_PROXY): " INPUT_PROXY_RETRY
        apply_proxy "${INPUT_PROXY_RETRY:-$DEFAULT_PROXY}"
        
        echo "   🔄 正在使用代理重试访问: $GO_OFFICIAL_DL_PAGE"
        GO_RELATIVE_PATH=$(fetch_go_path_from_url "$GO_OFFICIAL_DL_PAGE")
        if [ -n "$GO_RELATIVE_PATH" ]; then
            VERSION_FETCH_SUCCESS=true
        fi
    fi
fi

# 最终判定
if [ "$VERSION_FETCH_SUCCESS" = false ] || [ -z "$GO_RELATIVE_PATH" ]; then
    echo "❌ 致命错误：尝试了所有方法仍无法连接到 go.dev。请检查网络或更换加速源。"
    clear_proxy
    exit 1
fi

LATEST_VERSION_TAG=$(echo "$GO_RELATIVE_PATH" | grep -oP 'go\d+\.\d+(\.\d+)?')
# 这里是官方文件原始地址 (如 https://go.dev/dl/go1.22.0.linux-amd64.tar.gz)
GO_OFFICIAL_FILE_URL="https://go.dev${GO_RELATIVE_PATH}"

echo "📝 检测到最新版本: $LATEST_VERSION_TAG"

# --- 检查本地版本 ---
if command -v go &>/dev/null; then
    CURRENT_VERSION_TAG=$(go version | awk '{print $3}')
    if [[ "$CURRENT_VERSION_TAG" == "$LATEST_VERSION_TAG" ]]; then
        echo "✅ 当前已是最新版本，退出。"
        clear_proxy
        exit 0
    else
        echo "⚠️  需要更新 (当前: $CURRENT_VERSION_TAG -> 最新: $LATEST_VERSION_TAG)"
    fi
else
    echo "🆕 准备全新安装..."
fi

uninstall_old_go

# ==============================================================================
# 阶段 3: 文件下载 (文件下载的重试逻辑)
# ==============================================================================

GO_TAR_FILENAME=$(basename "$GO_OFFICIAL_FILE_URL")
TEMP_TAR_PATH="/tmp/$GO_TAR_FILENAME"
DOWNLOAD_SUCCESS=false

try_download() {
    local url=$1
    echo "📥 下载: $url"
    if curl -L --connect-timeout 15 --retry 2 -o "$TEMP_TAR_PATH" "$url"; then
        return 0
    else
        echo "   ⚠️  下载失败。"
        return 1
    fi
}

# 这里的逻辑与版本获取类似，但对象是 .tar.gz 文件

# 1. 优先尝试加速链接
if [[ "$USE_PROXY" == "no" && -n "$ACCEL_PREFIX" ]]; then
    FULL_ACCEL_FILE_URL="${ACCEL_PREFIX}${GO_OFFICIAL_FILE_URL}"
    echo "🚀 [加速通道]"
    if try_download "$FULL_ACCEL_FILE_URL"; then
        DOWNLOAD_SUCCESS=true
    else
        echo "   ⚠️ 加速通道失效，切换至官方通道..."
    fi
fi

# 2. 官方通道 (如果上面失败，或本身就有代理)
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "🐢 [官方通道]"
    if try_download "$GO_OFFICIAL_FILE_URL"; then
        DOWNLOAD_SUCCESS=true
    fi
fi

# 3. 二次救援：下载失败后询问代理
if [ "$DOWNLOAD_SUCCESS" = false ] && [[ "$USE_PROXY" == "no" ]]; then
    echo "❌ 直接下载全部失败。"
    echo "----------------------------------------------------"
    read -p "下载文件失败。是否现在配置代理重试？(y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "请输入代理地址 (默认: $DEFAULT_PROXY): " INPUT_PROXY_DL
        apply_proxy "${INPUT_PROXY_DL:-$DEFAULT_PROXY}"
        
        echo "🔄 [代理通道]"
        if try_download "$GO_OFFICIAL_FILE_URL"; then
            DOWNLOAD_SUCCESS=true
        fi
    fi
fi

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "❌ 错误：所有下载方式均已尝试失败。"
    rm -f "$TEMP_TAR_PATH"
    clear_proxy
    exit 1
fi

# ==============================================================================
# 阶段 4: 解压配置
# ==============================================================================

echo "📦 正在解压安装包..."
mkdir -p "$GO_INSTALL_DIR"
if ! tar -C "$GO_INSTALL_DIR" -xzf "$TEMP_TAR_PATH"; then
    echo "❌ 错误：解压失败，文件可能损坏。"
    rm -f "$TEMP_TAR_PATH"
    clear_proxy
    exit 1
fi
rm -f "$TEMP_TAR_PATH"

echo "⚙️  配置环境变量..."
GO_PROFILE_PATH_FILE="/etc/profile.d/go.sh"
if [ ! -f "$GO_PROFILE_PATH_FILE" ] || ! grep -q "export PATH=.*${GO_BIN_DIR}" "$GO_PROFILE_PATH_FILE"; then
    echo '#!/bin/sh' | tee "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "export PATH=\$PATH:${GO_BIN_DIR}" | tee -a "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "   已更新 $GO_PROFILE_PATH_FILE"
fi

export PATH=$PATH:${GO_BIN_DIR}

if command -v go &>/dev/null; then
    echo "🎉 Go 安装/升级成功！"
    go version
else
    echo "❌ 异常：安装完成后未找到 go 命令。"
    clear_proxy
    exit 1
fi

clear_proxy
echo "--- 脚本结束 ---"
echo "提示：请运行 'source /etc/profile' 使其立即生效。"
