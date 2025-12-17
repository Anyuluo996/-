#!/bin/bash

# ==============================================================================
# Linux Go 自动更新/安装脚本 (增强下载策略版)
# ==============================================================================

# --- 基础配置 ---
GO_INSTALL_DIR="/usr/local"
GO_BIN_DIR="${GO_INSTALL_DIR}/go/bin"

# 默认值设置
DEFAULT_PROXY="http://127.0.0.1:17890"
DEFAULT_ACCEL_PREFIX="https://steamproxy.9965421.xyz/"

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
        echo "🌐 已设置代理: $proxy_url"
    fi
}

# --- 辅助函数：清除代理环境变量 ---
clear_proxy() {
    if $PROXY_SET_FOR_SCRIPT; then
        unset HTTP_PROXY
        unset HTTPS_PROXY
        # 恢复运行脚本前的环境变量（如果有）
        [ -n "$ORIGINAL_HTTP_PROXY" ] && export HTTP_PROXY="$ORIGINAL_HTTP_PROXY"
        [ -n "$ORIGINAL_HTTPS_PROXY" ] && export HTTPS_PROXY="$ORIGINAL_HTTPS_PROXY"
        PROXY_SET_FOR_SCRIPT=false
        USE_PROXY="no"
        echo "🌐 已清除脚本设置的代理"
    fi
}

# --- 辅助函数：智能卸载旧版本 ---
uninstall_old_go() {
    echo "正在检测旧版本安装方式..."
    CURRENT_GO_PATH=$(command -v go)
    
    if [[ -z "$CURRENT_GO_PATH" ]]; then
        echo "未找到活跃的 go 命令，尝试清理标准目录..."
        rm -rf "${GO_INSTALL_DIR}/go"
        return
    fi

    echo "发现旧版本 Go 位于: $CURRENT_GO_PATH"

    if [[ "$CURRENT_GO_PATH" == *"/usr/local/go"* ]]; then
        echo "检测为手动安装版本，直接删除文件..."
        rm -rf "${GO_INSTALL_DIR}/go"
        echo "✅ 旧版本文件已清理。"
        return
    fi

    if [[ "$CURRENT_GO_PATH" == *"/usr/bin/go"* ]] || [[ "$CURRENT_GO_PATH" == *"/bin/go"* ]]; then
        echo "⚠️  检测为系统包管理器安装的版本。"
        if [ -f /etc/os-release ]; then . /etc/os-release; else rm -rf "${GO_INSTALL_DIR}/go"; return; fi
        case "$ID" in
            ubuntu|debian|kali|linuxmint|pop) apt-get remove -y golang-go golang && apt-get autoremove -y ;;
            centos|rhel|fedora|rocky|almalinux|amzn) 
                if command -v dnf &> /dev/null; then dnf remove -y golang; else yum remove -y golang; fi ;;
            arch|manjaro) pacman -Rs --noconfirm go ;;
            alpine) apk del go ;;
            opensuse*|sles) zypper remove -y go ;;
            *) echo "建议手动卸载包管理器版本。" ;;
        esac
        if [ -d "${GO_INSTALL_DIR}/go" ]; then rm -rf "${GO_INSTALL_DIR}/go"; fi
        return
    fi
    echo "Go 安装在非标准路径，尝试强制删除安装目录..."
    rm -rf "${GO_INSTALL_DIR}/go"
}

# ==============================================================================
# 阶段 1: 初始配置交互
# ==============================================================================

# 1. 询问是否开启代理
echo "----------------------------------------------------"
read -p "初始设置：是否需要设置代理？(y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "请输入代理地址 (默认: $DEFAULT_PROXY): " INPUT_PROXY
    CURRENT_PROXY=${INPUT_PROXY:-$DEFAULT_PROXY}
    apply_proxy "$CURRENT_PROXY"
    # 如果使用了代理，强制清空加速前缀（逻辑要求）
    ACCEL_PREFIX=""
else
    # 2. 如果不使用代理，询问是否配置加速链接
    read -p "是否设置下载加速链接(GitHub/SteamProxy等)? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then # 默认为 Yes
        read -p "请输入加速前缀 (默认: $DEFAULT_ACCEL_PREFIX): " INPUT_ACCEL
        ACCEL_PREFIX=${INPUT_ACCEL:-$DEFAULT_ACCEL_PREFIX}
        echo "🚀 将使用下载加速前缀: $ACCEL_PREFIX"
    fi
fi
echo "----------------------------------------------------"

# ==============================================================================
# 阶段 2: 获取版本信息
# ==============================================================================

echo "正在从 go.dev/dl 获取最新的 Go 版本信息..."

# 注意：如果既没开代理，网络环境又无法访问 go.dev 官网本身，这里就会失败
# 此时加速链接也救不了（因为还不知道版本号）
GO_RELATIVE_PATH=$(curl -s --connect-timeout 10 "https://go.dev/dl/" | \
  grep -oP 'href="/dl/go\d+\.\d+(\.\d+)?\.linux-amd64\.tar\.gz"' | \
  head -n 1 | \
  sed -E 's/href="(\/dl\/go[0-9]+\.[0-9]+(\.[0-9]+)?\.linux-amd64\.tar\.gz)"/\1/')

if [ -z "$GO_RELATIVE_PATH" ]; then
    echo "❌ 错误：未能获取到 Go 下载链接。"
    echo "可能是网络无法连接到 go.dev，或者未开启代理。"
    clear_proxy
    exit 1
fi

LATEST_VERSION_TAG=$(echo "$GO_RELATIVE_PATH" | grep -oP 'go\d+\.\d+(\.\d+)?')
# 官方原始下载链接
GO_OFFICIAL_URL="https://go.dev${GO_RELATIVE_PATH}" 

echo "官方最新版本: $LATEST_VERSION_TAG"

# --- 检查本地版本 ---
if command -v go &>/dev/null; then
    CURRENT_VERSION_TAG=$(go version | awk '{print $3}')
    echo "当前本地版本: $CURRENT_VERSION_TAG"
    if [[ "$CURRENT_VERSION_TAG" == "$LATEST_VERSION_TAG" ]]; then
        echo "✅ 当前已是最新版本，无需重新安装。"
        clear_proxy
        exit 0
    else
        echo "⚠️  发现新版本，准备升级..."
    fi
else
    echo "未检测到 Go 环境，准备开始安装..."
fi

uninstall_old_go

# ==============================================================================
# 阶段 3: 文件下载 (含回退与二次询问逻辑)
# ==============================================================================

GO_TAR_FILENAME=$(basename "$GO_OFFICIAL_URL")
TEMP_TAR_PATH="/tmp/$GO_TAR_FILENAME"
DOWNLOAD_SUCCESS=false

# 尝试下载的函数
try_download() {
    local url=$1
    echo "📥 正在尝试下载: $url"
    if curl -L --connect-timeout 10 --retry 2 -o "$TEMP_TAR_PATH" "$url"; then
        return 0
    else
        echo "⚠️  此链接下载失败。"
        return 1
    fi
}

# --- 逻辑 A: 如果初始设置了代理 (Use Proxy Mode) ---
if [[ "$USE_PROXY" == "yes" ]]; then
    # 直接使用官方链接下载
    if try_download "$GO_OFFICIAL_URL"; then
        DOWNLOAD_SUCCESS=true
    fi

# --- 逻辑 B: 如果未设置代理 (Direct / Accelerate Mode) ---
else
    # 1. 如果有加速前缀，先拼接下载
    if [ -n "$ACCEL_PREFIX" ]; then
        # 拼接逻辑：加速前缀 + 官方完整URL
        FULL_ACCEL_URL="${ACCEL_PREFIX}${GO_OFFICIAL_URL}"
        echo "尝试使用加速链接..."
        if try_download "$FULL_ACCEL_URL"; then
            DOWNLOAD_SUCCESS=true
        else
            echo "⚠️  加速链接不可用，退回官方原链接..."
        fi
    fi

    # 2. 如果加速下载未执行或失败，且尚未成功，尝试官方原链接 (无代理)
    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        echo "尝试直接使用官方链接 (无代理)..."
        if try_download "$GO_OFFICIAL_URL"; then
            DOWNLOAD_SUCCESS=true
        fi
    fi

    # 3. 如果官方直连也失败，进入“二次询问”逻辑
    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        echo "❌ 所有直接下载方式均失败。"
        echo "----------------------------------------------------"
        read -p "下载失败。是否现在配置代理重试？(y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "请输入代理地址 (默认: $DEFAULT_PROXY): " INPUT_PROXY_RETRY
            RETRY_PROXY=${INPUT_PROXY_RETRY:-$DEFAULT_PROXY}
            
            # 应用代理
            apply_proxy "$RETRY_PROXY"
            
            # 使用代理重试官方链接
            if try_download "$GO_OFFICIAL_URL"; then
                DOWNLOAD_SUCCESS=true
            fi
        fi
    fi
fi

# --- 最终检查下载结果 ---
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "❌ 错误：所有下载尝试均已失败，请检查网络设置。"
    rm -f "$TEMP_TAR_PATH"
    clear_proxy
    exit 1
fi

# ==============================================================================
# 阶段 4: 解压与配置
# ==============================================================================

echo "正在解压到 $GO_INSTALL_DIR..."
mkdir -p "$GO_INSTALL_DIR"
if ! tar -C "$GO_INSTALL_DIR" -xzf "$TEMP_TAR_PATH"; then
    echo "❌ 错误：解压失败，可能是下载的文件已损坏。"
    rm -f "$TEMP_TAR_PATH"
    clear_proxy
    exit 1
fi
rm -f "$TEMP_TAR_PATH"
echo "✅ 解压完成。"

echo "正在配置 PATH..."
GO_PROFILE_PATH_FILE="/etc/profile.d/go.sh"

if [ ! -f "$GO_PROFILE_PATH_FILE" ] || ! grep -q "export PATH=.*${GO_BIN_DIR}" "$GO_PROFILE_PATH_FILE"; then
    echo '#!/bin/sh' | tee "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "export PATH=\$PATH:${GO_BIN_DIR}" | tee -a "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "PATH 配置已写入 $GO_PROFILE_PATH_FILE"
fi

export PATH=$PATH:${GO_BIN_DIR}

echo "正在验证安装..."
if command -v go &>/dev/null; then
    NEW_VERSION=$(go version)
    echo "✅ Go 安装/升级成功！"
    echo "当前版本: $NEW_VERSION"
else
    echo "❌ 错误：安装后无法找到 go 命令，请检查路径配置。"
    clear_proxy
    exit 1
fi

# 清理环境
clear_proxy

echo "--- 脚本执行结束 ---"
echo "提示：请执行 'source /etc/profile' 或重新登录以刷新环境变量。"
