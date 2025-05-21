#!/bin/bash
# 设置环境变量及用户信息
export LC_ALL=C
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

# 生成唯一 UUID 作为身份识别
export UUID=${UUID:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}

# 设置可选环境变量（Telegram 通知和订阅上传）
export CHAT_ID=${CHAT_ID:-''} 
export BOT_TOKEN=${BOT_TOKEN:-''} 
export UPLOAD_URL=${UPLOAD_URL:-''}
export SUB_TOKEN=${SUB_TOKEN:-${UUID:0:8}}

# 根据主机名判断使用的域名
if [[ "$HOSTNAME" =~ ct8 ]]; then
    CURRENT_DOMAIN="ct8.pl"
elif [[ "$HOSTNAME" =~ hostuno ]]; then
    CURRENT_DOMAIN="useruno.com"
else
    CURRENT_DOMAIN="serv00.net"
fi

# 设置工作目录与公共目录，并清理旧文件
WORKDIR="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/public_html"
rm -rf "$WORKDIR" "$FILE_PATH" && mkdir -p "$WORKDIR" "$FILE_PATH" && chmod 777 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1

# 杀掉当前用户的非核心进程，避免冲突
bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1

# 检查是否安装 curl 或 wget，设置下载命令
command -v curl &>/dev/null && COMMAND="curl -so" || command -v wget &>/dev/null && COMMAND="wget -qO" || {
    echo "Error: neither curl nor wget found, please install one of them." >&2
    exit 1
}

# 检查并分配可用的 UDP 端口（hy2 使用 UDP）
check_port () {
  clear
  echo -e "\e[1;35m正在安装中,请稍等...\e[0m"
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  udp_ports=$(echo "$port_list" | grep -c "udp")

  # 如果没有UDP端口则尝试调整
  if [[ $udp_ports -lt 1 ]]; then
      echo -e "\e[1;91m没有可用的UDP端口,正在调整...\e[0m"
      if [[ $tcp_ports -ge 3 ]]; then
          tcp_port_to_delete=$(echo "$port_list" | awk '/tcp/ {print $1}' | head -n 1)
          devil port del tcp $tcp_port_to_delete
          echo -e "\e[1;32m已删除TCP端口: $tcp_port_to_delete\e[0m"
      fi
      while true; do
          udp_port=$(shuf -i 10000-65535 -n 1)
          result=$(devil port add udp $udp_port 2>&1)
          if [[ $result == *"Ok"* ]]; then
              echo -e "\e[1;32m已添加UDP端口: $udp_port"
              udp_port1=$udp_port
              break
          else
              echo -e "\e[1;33m端口 $udp_port 不可用，尝试其他端口...\e[0m"
          fi
      done
      echo -e "\e[1;32m端口已调整完成,如安装完后节点不通,访问 /restart 域名重启\e[0m"
      devil binexec on >/dev/null 2>&1
      kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
  else
      udp_ports=$(echo "$port_list" | awk '/udp/ {print $1}')
      udp_port1=$(echo "$udp_ports" | sed -n '1p')
  fi
  export PORT=$udp_port1
  echo -e "\e[1;35mhy2使用udp端口: $udp_port1\e[0m"
}
check_port

# 设置下载架构和地址（根据系统架构）
ARCH=$(uname -m) && DOWNLOAD_DIR="." && mkdir -p "$DOWNLOAD_DIR"
if [[ "$ARCH" == "arm" || "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    BASE_URL="https://github.com/eooce/test/releases/download/freebsd-arm64"
else
    BASE_URL="https://github.com/eooce/test/releases/download/freebsd"
fi
FILE_INFO=("$BASE_URL/hy2 web")

# 生成随机文件名函数（用于保存二进制）
declare -A FILE_MAP
generate_random_name() {
    local chars=abcdefghijklmnopqrstuvwxyz1234567890
    local name=""
    for i in {1..6}; do
        name="$name${chars:RANDOM%${#chars}:1}"
    done
    echo "$name"
}

# 下载 hy2 文件并保存为随机文件名
for entry in "${FILE_INFO[@]}"; do
    URL=$(echo "$entry" | cut -d ' ' -f 1)
    RANDOM_NAME=$(generate_random_name)
    NEW_FILENAME="$DOWNLOAD_DIR/$RANDOM_NAME"
    $COMMAND "$NEW_FILENAME" "$URL"
    echo -e "\e[1;32mDownloading $NEW_FILENAME\e[0m"
    chmod +x "$NEW_FILENAME"
    FILE_MAP[$(echo "$entry" | cut -d ' ' -f 2)]="$NEW_FILENAME"
done

# 生成自签 TLS 证书
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "$WORKDIR/server.key" -out "$WORKDIR/server.crt" -subj "/CN=${CURRENT_DOMAIN}" -days 36500

# 获取可用公网 IP（来自 devil 面板 + status 接口）
get_ip() {
  IP_LIST=($(devil vhost list | awk '/^[0-9]+/ {print $1}'))
  API_URL="https://status.eooce.com/api"
  IP=""
  THIRD_IP=${IP_LIST[2]}
  RESPONSE=$(curl -s --max-time 2 "${API_URL}/${THIRD_IP}")
  if [[ $(echo "$RESPONSE" | jq -r '.status') == "Available" ]]; then
      IP=$THIRD_IP
  else
      FIRST_IP=${IP_LIST[0]}
      RESPONSE=$(curl -s --max-time 2 "${API_URL}/${FIRST_IP}")
      [[ $(echo "$RESPONSE" | jq -r '.status') == "Available" ]] && IP=$FIRST_IP || IP=${IP_LIST[1]}
  fi
  echo "$IP"
}

# 获取主机 IP 并打印
HOST_IP=$(get_ip)
echo -e "\e[1;35m当前选择IP为: $HOST_IP 如安装完后节点不通可尝试重新安装\e[0m"

# 生成 hy2 配置文件 config.yaml
cat << EOF > config.yaml
listen: $HOST_IP:$PORT
tls:
  cert: "$WORKDIR/server.crt"
  key: "$WORKDIR/server.key"
auth:
  type: password
  password: "$UUID"
fastOpen: true
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
transport:
  udp:
    hopInterval: 30s
EOF

# 安装 Node.js 保活服务（用于自动重启 hy2）
install_keepalive () {
    echo -e "\n\e[1;35m正在安装保活服务中,请稍等......\e[0m"
    devil www del keep.${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    devil www add keep.${USERNAME}.${CURRENT_DOMAIN} nodejs /usr/local/bin/node18 > /dev/null 2>&1
    keep_path="$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"
    mkdir -p "$keep_path"
    app_file_url="https://hy2.ssss.nyc.mn/hy2.js"
    $COMMAND "${keep_path}/app.js" "$app_file_url" 

    # 写入环境变量到 .env 文件中
    cat > ${keep_path}/.env <<EOF
UUID=${UUID}
SUB_TOKEN=${SUB_TOKEN}
UPLOAD_URL=${UPLOAD_URL}
TELEGRAM_CHAT_ID=${CHAT_ID}
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
EOF

    # 添加前端页面与 Node 环境变量配置
    devil www add ${USERNAME}.${CURRENT_DOMAIN} php > /dev/null 2>&1
    index_url="https://github.com/eooce/Sing-box/releases/download/00/index.html"
    [ -f "${FILE_PATH}/index.html" ] || $COMMAND "${FILE_PATH}/index.html" "$index_url"

    # 设置 Node/npm 环境变量与路径
    ln -fs /usr/local/bin/node18 ~/bin/node
    ln -fs /usr/local/bin/npm18 ~/bin/npm
    mkdir -p ~/.npm-global
    npm config set prefix '~/.npm-global'
    echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> $HOME/.bash_profile && source $HOME/.bash_profile
    rm -rf $HOME/.npmrc
    cd ${keep_path} && npm install dotenv axios --silent
    rm -rf ${keep_path}/public/index.html
    devil www restart keep.${USERNAME}.${CURRENT_DOMAIN}

    # 测试保活服务是否启动成功
    if curl -skL "http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME}" | grep -q "running"; then
        echo -e "\e[1;32m\n全自动保活服务安装成功\n\e[0m"
    else
        echo -e "\e[1;31m\n保活失败，请检查 keep.${USERNAME}.${CURRENT_DOMAIN}/status\n\e[0m"
    fi
}

# 启动 hy2 主程序（带 config.yaml）
run() {
  if [ -e "$(basename ${FILE_MAP[web]})" ]; then
    nohup ./"$(basename ${FILE_MAP[web]})" server config.yaml >/dev/null 2>&1 &
    sleep 1
    pgrep -x "$(basename ${FILE_MAP[web]})" > /dev/null || {
      echo -e "\e[1;35m服务未运行，尝试重启...\e[0m"
      pkill -f "$(basename ${FILE_MAP[web]})"
      nohup ./"$(basename ${FILE_MAP[web]})" server config.yaml >/dev/null 2>&1 &
    }
  fi

  # 清理下载的临时文件
  for key in "${!FILE_MAP[@]}"; do
      [ -e "$(basename ${FILE_MAP[$key]})" ] && rm -rf "$(basename ${FILE_MAP[$key]})"
  done
}
run

# 构造名称和订阅信息
get_name() { [[ "$HOSTNAME" == "s1.ct8.pl" ]] && echo "CT8" || echo "$HOSTNAME" | cut -d '.' -f 1; }
NAME="$(get_name)-hy2-${USERNAME}"
ISP=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F\" '{print $26}' | sed -e 's/ /_/g' || echo "0")

# 输出 hy2 URI 链接
echo -e "\n\e[1;32mhy2安装成功\033[0m\n"
cat > ${FILE_PATH}/${SUB_TOKEN}_hy2.log <<EOF
hy2://$UUID@$HOST_IP:$PORT/?sni=www.bing.com&alpn=h3&insecure=1#$ISP-$NAME
EOF
cat ${FILE_PATH}/${SUB_TOKEN}_hy2.log

# 输出 Clash 配置段
echo -e "\n\e[1;35mClash:\033[0m"
cat << EOF
- name: $ISP-$NAME
  type: hy2
  server: $HOST_IP
  port: $PORT
  password: $UUID
  alpn:
    - h3
  sni: www.bing.com
  skip-cert-verify: true
  fast-open: true
EOF

# 输出二维码（终端二维码）
QR_URL="https://00.ssss.nyc.mn/qrencode"
$COMMAND "${WORKDIR}/qrencode" "$QR_URL" && chmod +x "${WORKDIR}/qrencode"
"${WORKDIR}/qrencode" -m 2 -t UTF8 "https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_hy2.log"
echo -e "\n\e[1;35m节点订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_hy2.log\e[0m\n"

# 清理配置文件，安装保活服务
rm -rf config.yaml fake_useragent_0.2.0.json
install_keepalive
