#!/bin/bash

# 字体颜色输出函数
function red()    { echo -e "\033[1;91m$1\033[0m"; }
function green()  { echo -e "\033[1;32m$1\033[0m"; }
function yellow() { echo -e "\033[1;33m$1\033[0m"; }
function purple() { echo -e "\033[1;35m$1\033[0m"; }

export LC_ALL=C
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

if [[ "$HOSTNAME" =~ ct8 ]]; then
  CURRENT_DOMAIN="ct8.pl"
elif [[ "$HOSTNAME" =~ hostuno ]]; then
  CURRENT_DOMAIN="useruno.com"
else
  CURRENT_DOMAIN="serv00.net"
fi

WORKDIR="$HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/web"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 1

cat << EOF > "$HOME/1.sh"
#!/bin/bash
echo "ok"
EOF
chmod +x "$HOME/1.sh"

if ! "$HOME/1.sh" > /dev/null; then
  devil binexec on
  echo "首次运行，请退出 SSH 后重新登录再执行此脚本"
  exit 0
fi

rm -rf "$WORKDIR"/*
sleep 1
devil port list | awk 'NR>1 && $2 == "udp" { print $1 }' | while read -r port; do
  devil port del udp "$port"
done

while true; do
  udp_port=$(shuf -i 30000-40000 -n 1)
  result=$(devil port add udp "$udp_port" 2>&1)
  [[ "$result" == *"Ok"* ]] && break
done
purple "已添加 UDP 端口：$udp_port"

read -p "请输入 UUID（回车自动生成）: " input_uuid
UUID=${input_uuid:-$(uuidgen)}
PASSWORD="$UUID"

read -p "请输入伪装域名（回车默认 bing.com）: " input_domain
MASQUERADE_DOMAIN=${input_domain:-bing.com}
purple "使用伪装域名：$MASQUERADE_DOMAIN"

# ---------- 新增：选择可用子域名 ----------
check_domain_blocked() {
    ping -c 1 -W 1 "$1" &> /dev/null
    return $?
}

choose_domain() {
    local index=$(echo "$HOSTNAME" | grep -o -E '[0-9]+')
    local base="serv00.com"
    local doms=("S${index}.${base}" "web${index}.${base}" "cache${index}.${base}")
    local available=()

    echo "检测子域名可用性："
    for dom in "${doms[@]}"; do
        if check_domain_blocked "$dom"; then
            echo "$dom 可用"
            available+=("$dom")
        else
            echo "$dom 被墙"
        fi
    done

    if [[ ${#available[@]} -eq 0 ]]; then
        red "❌ 所有子域名都被墙，退出部署"
        exit 1
    fi

    echo "请选择一个可用域名用于部署："
    select chosen in "${available[@]}"; do
        [[ -n "$chosen" ]] && echo "$chosen" && break || echo "无效选择"
    done
}

SELECTED_DOMAIN=$(choose_domain)
purple "最终部署域名：$SELECTED_DOMAIN"

curl -Lo hysteria2 https://download.hysteria.network/app/latest/hysteria-freebsd-amd64
chmod +x hysteria2

openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "$WORKDIR/web.key" \
  -out "$WORKDIR/web.crt" \
  -subj "/CN=${MASQUERADE_DOMAIN}" -days 36500

cat << EOF > "$WORKDIR/web.yaml"
listen: :$udp_port
tls:
  cert: $WORKDIR/web.crt
  key: $WORKDIR/web.key
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://${MASQUERADE_DOMAIN}
    rewriteHost: true
transport:
  udp:
    hopInterval: 30s
EOF

cat << EOF > "$WORKDIR/updateweb.sh"
#!/bin/bash
sleep \$((RANDOM % 30 + 10))
if ! pgrep -f hysteria2 > /dev/null; then
  cd "$WORKDIR"
  nohup ./hysteria2 server -c web.yaml > /dev/null 2>&1 &
fi
EOF
chmod +x "$WORKDIR/updateweb.sh"

"$WORKDIR/updateweb.sh"

cron_job="*/39 * * * * $WORKDIR/updateweb.sh # hysteria2_keepalive"
crontab -l 2>/dev/null | grep -q 'hysteria2_keepalive' || \
  (crontab -l 2>/dev/null; echo "$cron_job") | crontab -

TAG="$SELECTED_DOMAIN@$USERNAME-hy2"
SUB_URL="hysteria2://$PASSWORD@$SELECTED_DOMAIN:$udp_port/?sni=$MASQUERADE_DOMAIN&alpn=h3&insecure=1#$TAG"

read -p "请输入你的 Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "请输入你的 Telegram Chat ID: " TELEGRAM_CHAT_ID

ENCODED_LINK=$(echo -n "$SUB_URL" | base64)

MSG="HY2 部署成功 ✅\n\n$ENCODED_LINK"

curl -s -o /dev/null -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d text="$MSG"

green "=============================="
green "Hysteria2 已部署成功 "
green "已通过 Telegram 发送信息"
green "=============================="
