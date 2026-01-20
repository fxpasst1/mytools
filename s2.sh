#!/bin/bash
# 修复版 suoha x-tunnel 脚本 (支持 aarch64)

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")

# 1. 环境检测与基础包安装
n=0
OS_NAME=$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}')
for i in "${linux_os[@]}"; do
    if [ "$i" == "$OS_NAME" ]; then
        break
    else
        n=$((n+1))
    fi
done

if [ $n -eq 5 ]; then
    echo "当前系统 $OS_NAME 没有适配，尝试默认使用 APT"
    n=0
fi

# 安装必要组件
for cmd in screen curl lsof; do
    if ! command -v $cmd &> /dev/null; then
        echo "正在安装 $cmd..."
        ${linux_update[$n]} &> /dev/null
        ${linux_install[$n]} $cmd &> /dev/null
    fi
done

# 2. 核心功能函数
function quicktunnel(){
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64 | x64 | amd64 ) SUFFIX="amd64" ;;
        i386 | i686 ) SUFFIX="386" ;;
        armv8 | arm64 | aarch64 ) SUFFIX="arm64" ;;
        * ) echo "架构 $ARCH 不支持"; exit 1 ;;
    esac

    echo "检测到架构: $ARCH，正在准备下载..."

    # 下载文件
    [ ! -f "x-tunnel-linux" ] && curl -L "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-$SUFFIX" -o x-tunnel-linux
    [ ! -f "opera-linux" ] && curl -L "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-$SUFFIX" -o opera-linux
    [ ! -f "cloudflared-linux" ] && curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$SUFFIX" -o cloudflared-linux
    
    chmod +x cloudflared-linux x-tunnel-linux opera-linux

    # 获取随机端口
    get_free_port() {
        while true; do
            PORT=$((RANDOM % 60000 + 5000))
            if ! lsof -i :$PORT &> /dev/null; then
                echo $PORT
                return
            fi
        done
    }

    # 启动进程
    if [ "$opera" = "1" ]; then
        operaport=$(get_free_port)
        screen -dmUS opera ./opera-linux -country $country -socks-mode -bind-address "127.0.0.1:$operaport"
    fi

    wsport=$(get_free_port)
    if [ "$opera" = "1" ]; then
        screen -dmUS x-tunnel ./x-tunnel-linux -l ws://127.0.0.1:$wsport -token "$token" -f socks5://127.0.0.1:$operaport
    else
        screen -dmUS x-tunnel ./x-tunnel-linux -l ws://127.0.0.1:$wsport -token "$token"
    fi

    metricsport=$(get_free_port)
    screen -dmUS argo ./cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --url 127.0.0.1:$wsport --metrics 0.0.0.0:$metricsport

    # 获取域名逻辑
    echo "正在等待 Cloudflare 分配域名..."
    for i in {1..30}; do
        RESP=$(curl -s "http://127.0.0.1:$metricsport/metrics")
        if echo "$RESP" | grep -q 'userHostname='; then
            DOMAIN=$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/')
            clear
            echo "========================================"
            echo "恭喜！服务启动成功"
            echo "域名: $DOMAIN:443"
            [ -n "$token" ] && echo "Token: $token"
            echo "监控: http://$(curl -4 -s icanhazip.com):$metricsport/metrics"
            echo "========================================"
            return
        fi
        sleep 2
    done
    echo "获取域名超时，请检查网络或日志。"
}

# 3. 清理环境函数 (修复报错的核心)
function clean_all() {
    echo "正在清理旧进程..."
    # 强制杀死 screen 进程和相关二进制进程
    pkill -9 -f "x-tunnel-linux" &> /dev/null
    pkill -9 -f "opera-linux" &> /dev/null
    pkill -9 -f "cloudflared-linux" &> /dev/null
    pkill -9 screen &> /dev/null
    # 清理 screen 缓存
    rm -rf /root/.screen/* &> /dev/null
    screen -wipe &> /dev/null
    echo "清理完成。"
}

# 4. 主菜单
clear
echo "梭哈模式 - ARGO QUICK TUNNEL (ARM64 修复版)"
echo "1. 梭哈开启"
echo "2. 停止并清理"
echo "3. 退出"
read -p "选择模式 (默认1): " mode
mode=${mode:-1}

if [ "$mode" == "1" ]; then
    read -p "启用opera前置代理? (0.否[默认], 1.是): " opera
    opera=${opera:-0}
    if [ "$opera" == "1" ]; then
        read -p "国家代码 (默认AM): " country
        country=${country:-AM}
        country=${country^^}
    fi
    read -p "IP版本 (4或6, 默认4): " ips
    ips=${ips:-4}
    read -p "设置Token (可留空): " token

    clean_all
    quicktunnel
elif [ "$mode" == "2" ]; then
    clean_all
    echo "服务已停止。"
else
    exit 0
fi
