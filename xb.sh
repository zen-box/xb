#!/usr/bin/env bash
# xb - Xray 一键管理脚本
# 命令: xb (菜单) | xb help

VER="1.3.1"
BASE="/etc/xray-sh"
NODE_DIR="$BASE/nodes"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_DIR/config.json"
XB_BIN="/usr/local/bin/xb"
CORE_INSTALLER="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
DEFAULT_SNI="www.microsoft.com"
SERVER_IP=""

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info() { echo -e "${C}[信息]${N} $*"; }
ok()   { echo -e "${G}[成功]${N} $*"; }
warn() { echo -e "${Y}[警告]${N} $*"; }
err()  { echo -e "${R}[错误]${N} $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "请使用 root 用户运行"; }

# ───────────────────────── 基础工具 ─────────────────────────

get_ip() {
  [[ -n $SERVER_IP ]] && return
  local u ip
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com https://ip.sb; do
    ip=$(curl -s4 --max-time 5 "$u" | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then SERVER_IP=$ip; return; fi
  done
  ip=$(curl -s6 --max-time 5 https://api64.ipify.org | tr -d '[:space:]')
  SERVER_IP=${ip:-YOUR_SERVER_IP}
}

gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_path() { echo "/$(openssl rand -hex 4)"; }
urlenc()   { jq -rn --arg s "$1" '$s|@uri'; }

port_used() {
  local p=$1 f
  ss -tuln 2>/dev/null | awk 'NR>1{print $5}' | grep -Eq "[:.]${p}$" && return 0
  for f in "$NODE_DIR"/*.json; do
    [[ -f $f ]] && [[ $(jq -r .port "$f") == "$p" ]] && return 0
  done
  return 1
}

rand_port() {
  local p
  while :; do
    p=$(shuf -i 10000-60000 -n 1)
    port_used "$p" || { echo "$p"; return; }
  done
}

# resolve_port <输入|auto> [默认端口]  -> 输出可用端口
resolve_port() {
  local p=$1 d=$2
  if [[ -z $p || $p == auto ]]; then
    if [[ -n $d ]] && ! port_used "$d"; then echo "$d"; else rand_port; fi
    return 0
  fi
  if ! [[ $p =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    err "端口无效: $p"; return 1
  fi
  if port_used "$p"; then err "端口 $p 已被占用"; return 1; fi
  echo "$p"
}

# 生成 REALITY 密钥对 -> 全局 PRIV / PUB（兼容新旧版本 xray 的输出格式）
gen_keys() {
  local out
  out=$("$XRAY_BIN" x25519 2>&1)
  PRIV=$(echo "$out" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' | tr -d '[:space:]')
  PUB=$(echo "$out" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' | tr -d '[:space:]')
  [[ -n $PRIV && -n $PUB ]] || { err "生成 REALITY 密钥失败: $out"; return 1; }
}

ufw_active() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qiE 'Status:\s*active'
}

# ss 需要 TCP+UDP，REALITY / XHTTP 只走 TCP
fw_proto() {
  case $1 in ss) echo both ;; *) echo tcp ;; esac
}

fw_desc() {
  case $2 in
    both) echo "TCP+UDP $1" ;;
    udp)  echo "UDP $1" ;;
    *)    echo "TCP $1" ;;
  esac
}

ufw_allow() {
  local p=$1 proto=$2
  case $proto in
    both) ufw allow "$p"/tcp comment xb >/dev/null 2>&1
          ufw allow "$p"/udp comment xb >/dev/null 2>&1 ;;
    udp)  ufw allow "$p"/udp comment xb >/dev/null 2>&1 ;;
    *)    ufw allow "$p"/tcp comment xb >/dev/null 2>&1 ;;
  esac
}

ufw_deny() {
  local p=$1 proto=$2
  case $proto in
    both) ufw delete allow "$p"/tcp >/dev/null 2>&1
          ufw delete allow "$p"/udp >/dev/null 2>&1 ;;
    udp)  ufw delete allow "$p"/udp >/dev/null 2>&1 ;;
    *)    ufw delete allow "$p"/tcp >/dev/null 2>&1 ;;
  esac
}

# 仅当 UFW 已开启时询问；回车 = 放行。不主动启用 UFW。
open_fw() {
  local p=$1 proto=${2:-tcp}
  if ufw_active; then
    if confirm_yes "UFW 已开启，是否放行 $(fw_desc "$p" "$proto") ?"; then
      ufw_allow "$p" "$proto"
      ok "UFW 已放行 $(fw_desc "$p" "$proto")"
    else
      info "未改 UFW，请自行放行 $(fw_desc "$p" "$proto")"
    fi
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    if [[ $proto == both ]]; then
      firewall-cmd --permanent --add-port="$p"/tcp --add-port="$p"/udp >/dev/null 2>&1
    else
      firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1
    fi
    firewall-cmd --reload >/dev/null 2>&1
  fi
}

close_fw() {
  local p=$1 proto=${2:-tcp}
  ufw_active || return 0
  confirm_yes "是否删除 UFW 规则 $(fw_desc "$p" "$proto") ?" || return 0
  ufw_deny "$p" "$proto"
  ok "已删除 UFW $(fw_desc "$p" "$proto")"
}

# ───────────────────────── 配置生成 ─────────────────────────
# 节点元数据保存在 $NODE_DIR/<name>.json，统一由 jq 渲染成 xray 的 config.json

JQ_RENDER='
def render:
  if .type == "reality" or .type == "xhttp" then
    { tag: .name, port: .port, protocol: "vless",
      settings: {
        clients: [ {id: .uuid} + (if .type == "reality" then {flow: "xtls-rprx-vision"} else {} end) ],
        decryption: "none" },
      streamSettings: (
        { network: (if .type == "reality" then "tcp" else "xhttp" end),
          security: "reality",
          realitySettings: {
            show: false, dest: (.sni + ":443"), xver: 0,
            serverNames: [.sni], privateKey: .priv, shortIds: [.sid] } }
        + (if .type == "xhttp" then {xhttpSettings: {path: .path, mode: "auto"}} else {} end) ),
      sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] } }
  elif .type == "ss" then
    { tag: .name, port: .port, protocol: "shadowsocks",
      settings: { method: .method, password: .password, network: "tcp,udp" } }
  else empty end;
'

apply_config() {
  mkdir -p "$XRAY_DIR" "$NODE_DIR"
  local files=("$NODE_DIR"/*.json) nodes='[]' tmp
  [[ -e ${files[0]} ]] && nodes=$(jq -s . "${files[@]}")
  tmp=$(mktemp /tmp/xb-config.XXXXXX.json)

  jq -n --argjson nodes "$nodes" "$JQ_RENDER"'
    { log: { loglevel: "warning" },
      inbounds: [ $nodes[] | render ],
      outbounds: [ {protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "block"} ],
      routing: { domainStrategy: "AsIs",
                 rules: [ {type: "field", ip: ["geoip:private"], outboundTag: "block"} ] } }' > "$tmp" \
    || { err "生成配置失败"; rm -f "$tmp"; return 1; }

  if [[ $nodes == '[]' ]]; then
    install -m 644 "$tmp" "$XRAY_CONF"; rm -f "$tmp"
    systemctl stop xray 2>/dev/null
    warn "当前没有任何配置，xray 已停止"
    return 0
  fi

  local test_out
  if ! test_out=$("$XRAY_BIN" run -test -config "$tmp" 2>&1); then
    err "配置校验未通过，未应用:"; echo "$test_out" >&2
    rm -f "$tmp"; return 1
  fi

  install -m 644 "$tmp" "$XRAY_CONF"; rm -f "$tmp"
  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    err "xray 启动失败，请查看日志: journalctl -u xray -n 30 --no-pager"
    return 1
  fi
}

# ───────────────────────── 链接 / 展示 ─────────────────────────

node_url() {
  local f="$NODE_DIR/$1.json" h type name port uuid sni pbk sid path method password ui
  get_ip; h=$SERVER_IP; [[ $h == *:* ]] && h="[$h]"
  IFS='|' read -r type name port uuid sni pbk sid path method password < <(
    jq -r '[.type,.name,.port,.uuid,.sni,.pbk,.sid,.path,.method,.password] | map(. // "") | join("|")' "$f")
  case $type in
    reality)
      echo "vless://$uuid@$h:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$pbk&sid=$sid&type=tcp&headerType=none#xb-$name" ;;
    xhttp)
      echo "vless://$uuid@$h:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$pbk&sid=$sid&type=xhttp&path=$(urlenc "$path")&mode=auto#xb-$name" ;;
    ss)
      ui=$(printf '%s:%s' "$method" "$password" | base64 -w0 | tr '+/' '-_' | tr -d '=')
      echo "ss://$ui@$h:$port#xb-$name" ;;
  esac
}

print_qr() {
  local url=$1
  if ! command -v qrencode >/dev/null 2>&1; then
    warn "未安装 qrencode，无法显示二维码。Debian/Ubuntu: apt install qrencode"
    return 1
  fi
  echo -e "${Y}小火箭 / v2rayN 扫码导入:${N}"
  qrencode -t ANSIUTF8 -m 1 "$url"
  echo
}

show_node() {
  local tag=$1 f="$NODE_DIR/$1.json" url
  echo -e "${G}────────── $tag ──────────${N}"
  case $(jq -r .type "$f") in
    reality) echo "协议: VLESS + REALITY + Vision" ;;
    xhttp)   echo "协议: VLESS + REALITY + XHTTP（客户端需支持 XHTTP，sing-box 不支持）" ;;
    ss)      echo "协议: Shadowsocks 2022" ;;
  esac
  get_ip; echo "地址: $SERVER_IP"
  jq -r '[["端口",.port],["UUID",.uuid],["SNI",.sni],["PublicKey",.pbk],["ShortID",.sid],["路径",.path],["加密",.method],["密码",.password]]
         | .[] | select(.[1] != null and .[1] != "") | "\(.[0]): \(.[1])"' "$f"
  echo -e "${Y}链接:${N}"
  url=$(node_url "$tag")
  echo "$url"
  echo
  print_qr "$url" || true
}

# 选择节点 -> 全局 SEL。参数为关键词（按名称/端口匹配）
SEL=""
pick_node() {
  local kw=${1:-} f n i m=()
  for f in "$NODE_DIR"/*.json; do
    [[ -f $f ]] || continue
    n=$(basename "$f" .json)
    [[ -z $kw || $n == *"$kw"* ]] && m+=("$n")
  done
  (( ${#m[@]} )) || { err "没有匹配的配置，先用 xb add 添加"; return 1; }
  if (( ${#m[@]} == 1 )); then SEL=${m[0]}; return 0; fi
  echo "请选择配置:"
  for i in "${!m[@]}"; do echo "  $((i + 1))) ${m[i]}"; done
  read -rp "序号: " i
  if ! [[ $i =~ ^[0-9]+$ ]] || (( i < 1 || i > ${#m[@]} )); then err "无效选择"; return 1; fi
  SEL=${m[i-1]}
}

# ───────────────────────── 添加配置 ─────────────────────────

# add_vless <reality|xhttp> [port] [uuid] [sni]
add_vless() {
  local type=$1 port uuid sni sid path="" tag f
  port=$(resolve_port "$2" 443) || return 1
  uuid=${3:-auto}; [[ $uuid == auto ]] && uuid=$(gen_uuid)
  if ! [[ $uuid =~ ^[0-9a-fA-F-]{36}$ ]]; then err "UUID 格式不正确"; return 1; fi
  sni=${4:-auto}; [[ $sni == auto ]] && sni=$DEFAULT_SNI
  gen_keys || return 1
  sid=$(openssl rand -hex 8)
  [[ $type == xhttp ]] && path=$(gen_path)
  tag="$type-$port"; f="$NODE_DIR/$tag.json"

  mkdir -p "$NODE_DIR"
  jq -n --arg name "$tag" --arg type "$type" --argjson port "$port" --arg uuid "$uuid" \
        --arg sni "$sni" --arg priv "$PRIV" --arg pbk "$PUB" --arg sid "$sid" --arg path "$path" \
    '{name:$name,type:$type,port:$port,uuid:$uuid,sni:$sni,priv:$priv,pbk:$pbk,sid:$sid,path:$path}' > "$f"

  if ! apply_config; then rm -f "$f"; apply_config >/dev/null 2>&1; return 1; fi
  open_fw "$port" tcp
  ok "已添加 $tag"
  show_node "$tag"
}

# add_ss [port] [password]
add_ss() {
  local port pw method="2022-blake3-aes-128-gcm" tag f
  port=$(resolve_port "$1") || return 1
  pw=${2:-auto}; [[ $pw == auto ]] && pw=$(openssl rand -base64 16)
  if [[ $(printf '%s' "$pw" | base64 -d 2>/dev/null | wc -c) -ne 16 ]]; then
    err "SS2022 的密码必须是 16 字节的 base64（可用 auto 自动生成）"; return 1
  fi
  tag="ss-$port"; f="$NODE_DIR/$tag.json"
  mkdir -p "$NODE_DIR"
  jq -n --arg name "$tag" --argjson port "$port" --arg method "$method" --arg password "$pw" \
    '{name:$name,type:"ss",port:$port,method:$method,password:$password}' > "$f"

  if ! apply_config; then rm -f "$f"; apply_config >/dev/null 2>&1; return 1; fi
  open_fw "$port" both
  ok "已添加 $tag"
  show_node "$tag"
}

cmd_add() {
  local t=${1:-} p s
  if [[ -z $t ]]; then
    echo "选择协议:"
    echo "  1) VLESS + REALITY + Vision   (推荐，兼容性最好)"
    echo "  2) VLESS + REALITY + XHTTP    (需客户端支持 XHTTP)"
    echo "  3) Shadowsocks 2022"
    read -rp "请选择 [1-3]: " t
    case $t in 1) t=reality ;; 2) t=xhttp ;; 3) t=ss ;; *) err "无效选择"; return 1 ;; esac
    read -rp "端口 (回车自动): " p
    if [[ $t != ss ]]; then read -rp "SNI 伪装域名 (回车默认 $DEFAULT_SNI): " s; fi
    case $t in
      reality|xhttp) add_vless "$t" "${p:-auto}" auto "${s:-auto}" ;;
      ss) add_ss "${p:-auto}" auto ;;
    esac
    return
  fi
  shift
  case $t in
    r|reality) add_vless reality "$@" ;;
    x|xhttp)   add_vless xhttp "$@" ;;
    ss)        add_ss "$@" ;;
    *) err "未知协议: $t（可用: reality | xhttp | ss）"; return 1 ;;
  esac
}

# ───────────────────────── 查看 / 修改 / 删除 ─────────────────────────

cmd_info() {
  pick_node "$1" || return 1
  show_node "$SEL"
}

cmd_url() {
  local kw=${1:-} f n found=0
  for f in "$NODE_DIR"/*.json; do
    [[ -f $f ]] || continue
    n=$(basename "$f" .json)
    if [[ -z $kw || $n == *"$kw"* ]]; then echo "[$n]"; node_url "$n"; echo; found=1; fi
  done
  (( found )) || err "没有匹配的配置"
}

cmd_qr() {
  pick_node "$1" || return 1
  print_qr "$(node_url "$SEL")"
}

cmd_del() {
  pick_node "$1" || return 1
  local a p type proto
  p=$(jq -r .port "$NODE_DIR/$SEL.json")
  type=$(jq -r .type "$NODE_DIR/$SEL.json")
  proto=$(fw_proto "$type")
  read -rp "确认删除 $SEL ? [y/N] " a
  [[ $a =~ ^[yY]$ ]] || { info "已取消"; return; }
  rm -f "$NODE_DIR/$SEL.json"
  apply_config && ok "已删除 $SEL"
  close_fw "$p" "$proto"
}

# cmd_change [name] [port|id|sni|path|key|passwd] [value|auto]
cmd_change() {
  pick_node "$1" || return 1
  local tag=$SEL f="$NODE_DIR/$SEL.json" opt=$2 val=$3 type bak new newtag p oldp proto
  type=$(jq -r .type "$f")
  oldp=$(jq -r .port "$f")
  proto=$(fw_proto "$type")
  if [[ -z $opt ]]; then
    echo "修改项: port(端口) id(UUID) sni(伪装域名) path(路径,xhttp) key(REALITY密钥) passwd(密码,ss)"
    read -rp "请输入要修改的项: " opt
  fi
  bak=$(cat "$f")

  case $opt in
    port)
      [[ -z $val ]] && read -rp "新端口 (auto 随机): " val
      p=$(resolve_port "$val") || return 1
      new=$(jq --argjson p "$p" '.port=$p | .name=(.type + "-" + ($p|tostring))' "$f") ;;
    id)
      [[ $type == ss ]] && { err "该协议没有 UUID"; return 1; }
      [[ -z $val ]] && read -rp "新 UUID (auto 随机): " val
      [[ -z $val || $val == auto ]] && val=$(gen_uuid)
      [[ $val =~ ^[0-9a-fA-F-]{36}$ ]] || { err "UUID 格式不正确"; return 1; }
      new=$(jq --arg v "$val" '.uuid=$v' "$f") ;;
    sni)
      [[ $type == ss ]] && { err "该协议没有 SNI"; return 1; }
      [[ -z $val ]] && read -rp "新 SNI (auto 默认): " val
      [[ -z $val || $val == auto ]] && val=$DEFAULT_SNI
      new=$(jq --arg v "$val" '.sni=$v' "$f") ;;
    path)
      [[ $type != xhttp ]] && { err "只有 XHTTP 配置有路径"; return 1; }
      [[ -z $val ]] && read -rp "新路径 (auto 随机): " val
      [[ -z $val || $val == auto ]] && val=$(gen_path)
      [[ $val == /* ]] || val="/$val"
      new=$(jq --arg v "$val" '.path=$v' "$f") ;;
    key)
      [[ $type == ss ]] && { err "该协议没有 REALITY 密钥"; return 1; }
      gen_keys || return 1
      new=$(jq --arg a "$PRIV" --arg b "$PUB" --arg s "$(openssl rand -hex 8)" '.priv=$a|.pbk=$b|.sid=$s' "$f") ;;
    passwd)
      [[ $type != ss ]] && { err "只有 Shadowsocks 配置有密码"; return 1; }
      [[ -z $val ]] && read -rp "新密码 (auto 随机): " val
      [[ -z $val || $val == auto ]] && val=$(openssl rand -base64 16)
      [[ $(printf '%s' "$val" | base64 -d 2>/dev/null | wc -c) -eq 16 ]] || { err "密码必须是 16 字节的 base64"; return 1; }
      new=$(jq --arg v "$val" '.password=$v' "$f") ;;
    *) err "未知修改项: $opt"; return 1 ;;
  esac

  newtag=$(jq -r .name <<<"$new")
  rm -f "$f"
  echo "$new" > "$NODE_DIR/$newtag.json"
  if ! apply_config; then
    rm -f "$NODE_DIR/$newtag.json"; echo "$bak" > "$f"; apply_config >/dev/null 2>&1
    err "修改失败，已回滚"; return 1
  fi
  if [[ $opt == port ]]; then
    open_fw "$p" "$proto"
    [[ $p != "$oldp" ]] && close_fw "$oldp" "$proto"
  fi
  ok "已修改 $tag"
  show_node "$newtag"
}

# ───────────────────────── 系统管理 ─────────────────────────

xray_ver_current() {
  [[ -x $XRAY_BIN ]] || return 1
  "$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2; exit}'
}

# 取 Xray-core 最新 tag（去掉 v），失败返回 1
xray_ver_latest() {
  local tag
  tag=$(curl -fsSL --max-time 12 -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
    | jq -r '.tag_name // empty')
  if [[ -z $tag || $tag == null ]]; then
    tag=$(curl -fsSLI --max-time 12 -o /dev/null -w '%{url_effective}' \
      https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null)
    tag=${tag##*/}
  fi
  tag=${tag#v}
  [[ -n $tag && $tag != latest && $tag != releases ]] || return 1
  echo "$tag"
}

confirm_yes() {
  local a
  if [[ ! -t 0 ]]; then return 0; fi
  read -rp "$1 [Y/n] " a
  [[ -z $a || $a =~ ^[yY]$ ]]
}

install_core() {
  info "安装 / 更新 Xray 内核（官方 Xray-install 脚本）..."
  local args=(install)
  [[ -n $1 ]] && args+=(--version "${1#v}")
  bash -c "$(curl -fsSL "$CORE_INSTALLER")" @ "${args[@]}" || return 1
  [[ -x $XRAY_BIN ]] || return 1
}

cmd_update_check() {
  local cur latest
  cur=$(xray_ver_current 2>/dev/null || true)
  echo "脚本版本: $VER"
  echo "Xray 当前: ${cur:-未安装}"
  if latest=$(xray_ver_latest); then
    echo "Xray 最新: $latest"
    if [[ -n $cur && $cur == "$latest" ]]; then
      ok "内核已是最新"
    elif [[ -n $cur ]]; then
      warn "内核有新版本: $cur -> $latest"
    else
      warn "尚未安装内核，最新为 $latest"
    fi
  else
    err "无法获取 GitHub 最新版本（网络或 API 限制）"
  fi
}

update_core() {
  local pin=$1 cur latest
  cur=$(xray_ver_current 2>/dev/null || true)

  if [[ -n $pin ]]; then
    pin=${pin#v}
    info "当前内核: ${cur:-未安装}"
    info "指定版本: $pin"
    [[ $cur == "$pin" ]] && { ok "已是该版本 $cur"; return 0; }
    confirm_yes "是否安装 $pin ?" || { info "已取消"; return; }
    install_core "$pin" || die "内核更新失败"
  else
    latest=$(xray_ver_latest) || die "无法检测最新版本，可指定: xb update core <版本>"
    info "当前内核: ${cur:-未安装}"
    info "最新版本: $latest"
    if [[ -n $cur && $cur == "$latest" ]]; then
      ok "已是最新版本 $cur"
      return 0
    fi
    confirm_yes "发现新版本，是否更新 ${cur:-未安装} -> $latest ?" || { info "已取消"; return; }
    install_core "$latest" || die "内核更新失败"
  fi
  [[ -s $XRAY_CONF ]] && systemctl restart xray
  ok "内核已更新: $("$XRAY_BIN" version | head -1)"
}

update_sh() {
  local raw tmp remote_ver
  raw=$(cat "$BASE/repo" 2>/dev/null)
  [[ -n $raw ]] || die "未找到脚本仓库地址 ($BASE/repo)。把脚本放到 GitHub 后，用 install.sh 安装才会写入。"
  tmp=$(mktemp)
  curl -fsSL "$raw/xb.sh" -o "$tmp" && bash -n "$tmp" || { rm -f "$tmp"; die "下载 xb.sh 失败: $raw/xb.sh"; }
  remote_ver=$(awk -F= '/^VER=/{gsub(/"/,"",$2); print $2; exit}' "$tmp")
  info "当前脚本: $VER"
  info "仓库脚本: ${remote_ver:-未知}"
  if [[ -n $remote_ver && $remote_ver == "$VER" ]]; then
    ok "脚本已是最新 $VER"
    rm -f "$tmp"
    return 0
  fi
  confirm_yes "是否更新脚本 ${VER} -> ${remote_ver:-仓库版本} ?" || { rm -f "$tmp"; info "已取消"; return; }
  install -m 755 "$tmp" "$XB_BIN"; rm -f "$tmp"
  ok "脚本已更新为 ${remote_ver:-仓库版本}"
}

cmd_update() {
  case ${1:-core} in
    check) cmd_update_check ;;
    core)  update_core "$2" ;;
    sh)    update_sh ;;
    *) err "用法: xb update [check | core [版本] | sh]" ;;
  esac
}

cmd_bbr() {
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then
    ok "BBR 已经启用"; return
  fi
  modprobe tcp_bbr 2>/dev/null
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    err "当前内核不支持 BBR（需要 4.9+）"; return 1
  fi
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-xb-bbr.conf
  sysctl --system >/dev/null 2>&1
  ok "BBR 已启用: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

cmd_uninstall() {
  local a
  read -rp "将卸载 Xray 与本脚本，并删除所有配置，确认? [y/N] " a
  [[ $a =~ ^[yY]$ ]] || { info "已取消"; return; }
  bash -c "$(curl -fsSL "$CORE_INSTALLER")" @ remove --purge
  rm -rf "$BASE" "$XB_BIN" /etc/sysctl.d/99-xb-bbr.conf
  ok "已卸载"
  exit 0
}

cmd_status() {
  echo -n "Xray 版本: "; "$XRAY_BIN" version 2>/dev/null | head -1
  systemctl --no-pager -l status xray 2>/dev/null | head -n 12
  echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

cmd_list() {
  local f any=0
  for f in "$NODE_DIR"/*.json; do
    [[ -f $f ]] || continue
    jq -r '"  \(.name)\t端口 \(.port)\t\(.type)"' "$f"; any=1
  done
  (( any )) || echo "  （暂无配置）"
}

cmd_first_run() {
  need_root
  mkdir -p "$NODE_DIR"
  if [[ ! -x $XRAY_BIN ]]; then
    install_core || die "Xray 内核安装失败，请检查服务器能否访问 GitHub"
  fi
  systemctl enable xray >/dev/null 2>&1
  if ls "$NODE_DIR"/*.json >/dev/null 2>&1; then
    apply_config
  else
    info "自动创建一个 VLESS-REALITY 配置..."
    add_vless reality auto auto auto || die "创建默认配置失败"
  fi
  echo
  ok "安装完成！输入 ${G}xb${N} 打开管理菜单，${G}xb help${N} 查看全部命令"
  warn "如果服务商有外部防火墙/安全组，请放行上面的端口（TCP，SS 还需 UDP）"
}

# ───────────────────────── 菜单 / 帮助 ─────────────────────────

show_help() {
  cat <<EOF
xb v$VER - Xray 一键管理脚本

用法: xb [命令] [参数]

添加配置:
  xb add                           交互式添加
  xb add reality [端口] [uuid] [sni]   VLESS-REALITY-Vision (可简写 r)
  xb add xhttp   [端口] [uuid] [sni]   VLESS-REALITY-XHTTP  (可简写 x)
  xb add ss      [端口] [密码]         Shadowsocks 2022
  参数填 auto 或省略即自动生成，例: xb add r 443 auto dl.google.com
  创建 / 修改 / xb info 会打印 vless:// 或 ss:// 链接和二维码，小火箭可扫码导入

查看 / 修改 / 删除 (name 为关键词，如 reality、443，可省略):
  xb list                          列出所有配置
  xb info [name]                   交互选择已创建的协议，打印详情 / URL / 二维码
  xb ls                            列出全部协议名称和端口
  xb url  [name]                   只显示分享链接
  xb qr   [name]                   单独再显示一次二维码
  xb change [name] [项] [值]       修改配置
  xb port|id|sni|path|key|passwd [name] [值]    修改某一项的快捷写法
  xb del  [name]                   删除配置

系统:
  xb status | start | stop | restart
  xb log                           查看实时日志
  xb bbr                           启用 BBR
  xb ip                            显示服务器 IP
  xb update check                  检测内核是否有新版本
  xb update [core [版本] | sh]     检测后更新内核 / 从 GitHub 更新脚本
  xb uninstall                     卸载

配置文件目录: $NODE_DIR ；xray 配置: $XRAY_CONF
EOF
}

menu() {
  local c st
  while :; do
    st=$(systemctl is-active xray 2>/dev/null)
    echo
    echo -e "${G}=== Xray 管理脚本 v$VER ===${N}  状态: ${Y}${st:-未安装}${N}"
    cmd_list
    echo "--------------------------------"
    echo " 1) 添加配置      2) 查看链接/二维码  3) 修改配置"
    echo " 4) 删除配置      5) 再显示二维码     6) 重启 Xray"
    echo " 7) 查看日志      8) 检测/更新内核   9) 更新脚本"
    echo "10) 启用 BBR     11) 运行状态       12) 卸载"
    echo " 0) 退出"
    read -rp "请选择 [0-12]: " c
    case $c in
      1) cmd_add ;;
      2) cmd_info ;;
      3) cmd_change ;;
      4) cmd_del ;;
      5) cmd_qr ;;
      6) systemctl restart xray && ok "已重启" ;;
      7) echo "Ctrl+C 退出日志"; journalctl -u xray -n 50 -f ;;
      8) cmd_update core ;;
      9) cmd_update sh ;;
      10) cmd_bbr ;;
      11) cmd_status ;;
      12) cmd_uninstall ;;
      0|"") exit 0 ;;
      *) err "无效选择" ;;
    esac
  done
}

main() {
  local c=${1:-}
  case $c in help|-h|--help) show_help; exit 0 ;; version|-v|--version) echo "xb v$VER"; exit 0 ;; esac
  need_root
  case $c in
    "")                menu ;;
    first-run)         cmd_first_run ;;
    add|a)             shift; cmd_add "$@" ;;
    list|ls)           cmd_list ;;
    info|i)            cmd_info "$2" ;;
    url|u)             cmd_url "$2" ;;
    qr)                cmd_qr "$2" ;;
    del|rm)            cmd_del "$2" ;;
    change|c)          cmd_change "$2" "$3" "$4" ;;
    port|id|sni|path|key|passwd) cmd_change "$2" "$c" "$3" ;;
    start)             systemctl start xray && ok "已启动" ;;
    stop)              systemctl stop xray && ok "已停止" ;;
    restart|r)         systemctl restart xray && ok "已重启" ;;
    status|s)          cmd_status ;;
    log)               journalctl -u xray -n 50 -f ;;
    bbr)               cmd_bbr ;;
    ip)                get_ip; echo "$SERVER_IP" ;;
    update)            cmd_update "$2" "$3" ;;
    uninstall)         cmd_uninstall ;;
    *)                 err "未知命令: $c"; show_help; exit 1 ;;
  esac
}

main "$@"
