#!/bin/bash

# ==============================================================================
# Linux Go 自动更新/安装脚本 (智能系统检测版)
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
   exit 1
fi

echo "--- 开始 Go 安装/更新脚本 ---"

# --- 辅助函数：智能卸载旧版本 (基于 /etc/os-release) ---
uninstall_old_go() {
    echo "正在检测旧版本安装方式..."
    
    # 获取当前 go 命令的路径
    CURRENT_GO_PATH=$(command -v go)
    
    if [[ -z "$CURRENT_GO_PATH" ]]; then
        echo "未找到活跃的 go 命令，尝试清理标准目录..."
        rm -rf "${GO_INSTALL_DIR}/go"
        return
    fi

    echo "发现旧版本 Go 位于: $CURRENT_GO_PATH"

    # 1. 判断是否为手动安装 (通常在 /usr/local/go)
    if [[ "$CURRENT_GO_PATH" == *"/usr/local/go"* ]]; then
        echo "检测为手动安装版本，直接删除文件..."
        rm -rf "${GO_INSTALL_DIR}/go"
        echo "✅ 旧版本文件已清理。"
        return
    fi

    # 2. 判断是否为系统包管理器安装 (通常在 /usr/bin/go)
    if [[ "$CURRENT_GO_PATH" == *"/usr/bin/go"* ]] || [[ "$CURRENT_GO_PATH" == *"/bin/go"* ]]; then
        echo "⚠️  检测为系统包管理器安装的版本。"
        
        # 读取系统发行版信息
        if [ -f /etc/os-release ]; then
            . /etc/os-release
        else
            echo "无法读取 /etc/os-release，无法自动识别系统类型。"
            echo "尝试强制删除文件..."
            rm -rf "${GO_INSTALL_DIR}/go"
            return
        fi

        echo "检测到系统 ID: $ID (衍生系: $ID_LIKE)"

        case "$ID" in
            ubuntu|debian|kali|linuxmint|pop)
                echo "系统系别: Debian/Ubuntu"
                # 同时尝试移除 golang-go 和 golang，并清理依赖
                apt-get remove -y golang-go golang && apt-get autoremove -y
                ;;
            centos|rhel|fedora|rocky|almalinux|amzn)
                echo "系统系别: RHEL/Fedora"
                if command -v dnf &> /dev/null; then
                    dnf remove -y golang
                else
                    yum remove -y golang
                fi
                ;;
            arch|manjaro)
                echo "系统系别: Arch Linux"
                pacman -Rs --noconfirm go
                ;;
            alpine)
                echo "系统系别: Alpine"
                apk del go
                ;;
            opensuse*|sles)
                echo "系统系别: OpenSUSE"
                zypper remove -y go
                ;;
            *)
                # 尝试通过 ID_LIKE 匹配 (处理基于上述发行版的冷门系统)
                if [[ "$ID_LIKE" == *"debian"* ]] || [[ "$ID_LIKE" == *"ubuntu"* ]]; then
                    apt-get remove -y golang-go golang && apt-get autoremove -y
                elif [[ "$ID_LIKE" == *"rhel"* ]] || [[ "$ID_LIKE" == *"fedora"* ]]; then
                     if command -v dnf &> /dev/null; then dnf remove -y golang; else yum remove -y golang; fi
                else
                    echo "❌ 未能识别的具体发行版逻辑，跳过包管理器卸载。"
                    echo "建议手动执行卸载命令。"
                fi
                ;;
        esac
        
        # 兜底清理：确保 /usr/local/go 也被删干净（防止混合安装的情况）
        if [ -d "${GO_INSTALL_DIR}/go" ]; then
             echo "清理残留目录..."
             rm -rf "${GO_INSTALL_DIR}/go"
        fi
        return
    fi
    
    # 其他非标准路径
    echo "Go 安装在非标准路径 ($CURRENT_GO_PATH)，尝试强制删除安装目录..."
    rm -rf "${GO_INSTALL_DIR}/go"
}

# --- 询问是否设置代理 ---
read -p "是否需要设置代理？(y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    USE_PROXY="yes"
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    PROXY_SET_FOR_SCRIPT=true
fi

# --- 1. 获取最新的 Go Linux AMD64 下载链接与版本号 ---
echo "正在从 go.dev/dl 获取最新的 Go 版本信息..."

GO_RELATIVE_PATH=$(curl -s "https://go.dev/dl/" | \
  grep -oP 'href="/dl/go\d+\.\d+(\.\d+)?\.linux-amd64\.tar\.gz"' | \
  head -n 1 | \
  sed -E 's/href="(\/dl\/go[0-9]+\.[0-9]+(\.[0-9]+)?\.linux-amd64\.tar\.gz)"/\1/')

if [ -z "$GO_RELATIVE_PATH" ]; then
    echo "错误：未能获取到 Go 下载链接。请检查网络连接。"
    if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
    exit 1
fi

LATEST_VERSION_TAG=$(echo "$GO_RELATIVE_PATH" | grep -oP 'go\d+\.\d+(\.\d+)?')
GO_DOWNLOAD_URL="https://go.dev${GO_RELATIVE_PATH}"
echo "官方最新版本: $LATEST_VERSION_TAG"

# --- 2. 检查本地版本并对比 ---
if command -v go &>/dev/null; then
    CURRENT_VERSION_TAG=$(go version | awk '{print $3}')
    echo "当前本地版本: $CURRENT_VERSION_TAG"

    if [[ "$CURRENT_VERSION_TAG" == "$LATEST_VERSION_TAG" ]]; then
        echo "✅ 当前已是最新版本 ($CURRENT_VERSION_TAG)，无需重新安装。"
        if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
        exit 0
    else
        echo "⚠️  发现版本不一致 (本地: $CURRENT_VERSION_TAG | 最新: $LATEST_VERSION_TAG)，准备升级..."
    fi
else
    echo "未检测到 Go 环境，准备开始安装 $LATEST_VERSION_TAG..."
fi

# --- 3. 调用卸载函数清理旧版本 ---
uninstall_old_go

# --- 4. 下载并解压 Go ---
GO_TAR_FILENAME=$(basename "$GO_DOWNLOAD_URL")
TEMP_TAR_PATH="/tmp/$GO_TAR_FILENAME"

echo "正在下载: $GO_DOWNLOAD_URL"
if ! curl -L -o "$TEMP_TAR_PATH" "$GO_DOWNLOAD_URL"; then
    echo "错误：下载失败。"
    rm -f "$TEMP_TAR_PATH"
    if $PROXY_SET_FOR_SCRIPT; then unset HTTP_PROXY HTTPS_PROXY; fi
    exit 1
fi

echo "正在解压到 $GO_INSTALL_DIR..."
# 确保目录存在
mkdir -p "$GO_INSTALL_DIR"
if ! tar -C "$GO_INSTALL_DIR" -xzf "$TEMP_TAR_PATH"; then
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
    echo '#!/bin/sh' | tee "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "export PATH=\$PATH:${GO_BIN_DIR}" | tee -a "$GO_PROFILE_PATH_FILE" > /dev/null
    echo "PATH 配置已写入 $GO_PROFILE_PATH_FILE"
fi

# 临时应用 PATH
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
fi

echo "--- 脚本执行结束 ---"
echo "提示：请执行 'source /etc/profile' 或重新登录以刷新环境变量。"
