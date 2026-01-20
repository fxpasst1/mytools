#!/bin/bash
# suoha x-tunnel (fixed and more robust)
set -euo pipefail
IFS=$'\n\t'

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")

n=0

# 获取系统名（取 PRETTY_NAME 的第一个单词）
if [ -r /etc/os-release ]; then
    os_name=$(grep -i PRETTY_NAME /etc/os-release | cut -d\" -f2 | awk '{print $1}' || true)
else
    os_name=""
fi

found=0
for idx in "${!linux_os[@]}"; do
    if [ "${linux_os[$idx]}" = "$os_name" ]; then
        n=$idx
        found=1
        break
    fi
done

if [ "$found" -ne 1 ]; then
    echo "当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d\" -f2 || echo unknown)没有适配"
    echo "默认使用APT包管理器"
    n=0
fi

# Helper to run update/install safely
run_update() {
    eval "${linux_update[$n]}"
}
run_install() {
    pkg="$1"
    eval "${linux_install[$n]} $pkg"
}

# Use command -v to check existence
if ! command -v screen >/dev/null 2>&1; then
    run_update
    run_install screen
fi
if ! command -v lsof >/dev/null 2>&1; then
    run_update
    run_install lsof
fi
if ! command -v curl >/dev/null 2>&1; then
    run_update
    run_install curl
fi

get_free_port() {
    # 返回范围在 1025-65535 的随机空闲端口
    while true; do
        PORT=$((RANDOM % 64511 + 1025))
        if ! lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
            echo "$PORT"
            return
        fi
    done
}

function quicktunnel() {
    case "$(uname -m)" in
        x86_64|x64|amd64)
            arch="amd64"
            ;;
        i386|i686)
            arch="386"
            ;;
        armv8|arm64|aarch64)
            arch="arm64"
            ;;
        *)
            echo "当前架构 $(uname -m) 没有适配"
            exit 1
            ;;
    esac

    # 下载二进制文件（如果不存在）
    [ -f "x-tunnel-linux" ] || curl -L "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-${arch}" -o x-tunnel-linux
    [ -f "opera-linux" ] || curl -L "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-${arch}" -o opera-linux
    [ -f "cloudflared-linux" ] || curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o cloudflared-linux

    chmod +x cloudflared-linux x-tunnel-linux opera-linux

    if [ "${opera:-0}" = "1" ]; then
        operaport=$(get_free_port)
        screen -dmUS opera ./opera-linux -country "${country:-AM}" -socks-mode -bind-address "127.0.0.1:$operaport"
    fi

    sleep 1
    wsport=$(get_free_port)

    if [ -z "${token:-}" ]; then
        if [ "${opera:-0}" = "1" ]; then
            screen -dmUS x-tunnel ./x-tunnel-linux -l ws://127.0.0.1:"$wsport" -f socks5://127.0.0.1:"$operaport"
        else
            screen -dmUS x-tunnel ./x-tunnel-linux -l ws://127.0.0.1:"$wsport"
        fi
    else
        if [ "${opera:-0}" = "1" ]; then
            screen -dmUS x-tunnel ./x-tunnel-linux -l ws://127.0.0.1:"$wsport" -token "$token" -f socks5://127.0.0.1:"$operaport"
        else
            screen -dmUS x-tunnel ./x-tunnel-linux -l ws://127.0.0.1:"$wsport" -token "$token"
        fi
    fi

    metricsport=$(get_free_port)
    ./cloudflared-linux update || true
    screen -dmUS argo ./cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel --url 127.0.0.1:"$wsport" --metrics 0.0.0.0:"$metricsport"

    while true; do
        echo "正在尝试获取内容..."
        RESP=$(curl -s "http://127.0.0.1:$metricsport/metrics" || true)

        if echo "$RESP" | grep -q 'userHostname='; then
            echo "获取成功，正在解析..."
            DOMAIN=$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
            echo "提取到的域名：$DOMAIN"
            break
        else
            echo "未获取到userHostname，1秒后重试..."
            sleep 1
        fi
    done

    clear
    if [ -z "${token:-}" ]; then
        echo "未设置token, 链接为: $DOMAIN:443"
    else
        echo "已设置token, 链接为: $DOMAIN:443 身份令牌: $token"
    fi

    # 给出查询 metrics 的示例（仅一次请求）
    cfip=$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^ip=' | cut -d= -f2 || true)
    if [ -n "$cfip" ]; then
        echo "可以访问 http://$cfip:$metricsport/metrics 查找 userHostname"
    fi
}

clear
echo "梭哈模式不需要自己提供域名, 使用 CF ARGO QUICK TUNNEL 创建快速链接"
echo "梭哈模式在重启或者脚本再次运行后失效, 如果需要使用需要再次运行创建"

printf '\n梭哈是一种智慧!!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n\n'

echo "1. 梭哈模式"
echo "2. 停止服务"
echo "3. 清空缓存"
echo -e "0. 退出脚本\n"
read -p "请选择模式(默认1): " mode
mode=${mode:-1}

if [ "$mode" = "1" ]; then
    read -p "是否启用opera前置代理(0.不启用[默认],1.启用): " opera
    opera=${opera:-0}
    if [ "$opera" = "1" ]; then
        echo "注意: opera前置代理仅支持AM,AS,EU地区"
        echo "AM: 北美地区"
        echo "AS: 亚太地区"
        echo "EU: 欧洲地区"
        read -p "请输入opera前置代理的国家代码(默认AM): " country
        country=${country:-AM}
        country=${country^^}
        if [ "$country" != "AM" ] && [ "$country" != "AS" ] && [ "$country" != "EU" ]; then
            echo "请输入正确的opera前置代理国家代码"
            exit 1
        fi
    fi

    if [ "$opera" != "0" ] && [ "$opera" != "1" ]; then
        echo "请输入正确的opera前置代理模式"
        exit 1
    fi

    read -p "请选择cloudflared连接模式IPV4或者IPV6(输入4或6,默认4): " ips
    ips=${ips:-4}
    if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then
        echo "请输入正确的cloudflared连接模式"
        exit 1
    fi

    read -p "请设置x-tunnel的token(可留空): " token
    screen -wipe >/dev/null 2>&1 || true

    # 尝试优雅停止已有 session
    for s in x-tunnel opera argo; do
        if screen -list | grep -q "$s"; then
            screen -S "$s" -X quit || true
            # 等待 session 消失
            while screen -list | grep -q "$s"; do
                echo "等待$s退出..."
                sleep 1
            done
        fi
    done

    clear
    sleep 1
    quicktunnel

elif [ "$mode" = "2" ]; then
    screen -wipe >/dev/null 2>&1 || true
    for s in x-tunnel opera argo; do
        if screen -list | grep -q "$s"; then
            screen -S "$s" -X quit || true
            while screen -list | grep -q "$s"; do
                echo "等待$s退出..."
                sleep 1
            done
        fi
    done
    clear

elif [ "$mode" = "3" ]; then
    screen -wipe >/dev/null 2>&1 || true
    for s in x-tunnel opera argo; do
        if screen -list | grep -q "$s"; then
            screen -S "$s" -X quit || true
            while screen -list | grep -q "$s"; do
                echo "等待$s退出..."
                sleep 1
            done
        fi
    done
    clear
    rm -f cloudflared-linux x-tunnel-linux opera-linux

else
    echo "退出成功"
    exit 0
fi
