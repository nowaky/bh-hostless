
#!/bin/sh

# Hostless 可写目录
mkdir -p /app/.cache/baihu/data
mkdir -p /app/.cache/baihu/configs
mkdir -p /app/.cache/baihu/envs

# 自动识别平台端口
BAIHU_PORT="${PORT:-${BH_SERVER_PORT:-8052}}"
BH_SERVER_PORT="$BAIHU_PORT"
BH_SERVER_HOST="${BH_SERVER_HOST:-0.0.0.0}"

export BH_SERVER_PORT
export BH_SERVER_HOST

echo "======================================"
echo "Baihu 启动与恢复"
echo "监听端口：${BAIHU_PORT}"
echo "======================================"

# 配置 PM2 运行环境
PM2_PATH_FILE="/usr/local/share/baihu/pm2-path"

if [ ! -s "$PM2_PATH_FILE" ]; then
    echo "错误：PM2 路径文件不存在：$PM2_PATH_FILE"
    exit 1
fi

PM2_PATH="$(cat "$PM2_PATH_FILE")"
NODE_BIN="$(mise which node)"

if [ -z "$PM2_PATH" ] || [ ! -f "$PM2_PATH" ]; then
    echo "错误：PM2 文件不存在：$PM2_PATH"
    exit 1
fi

if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
    echo "错误：Node.js 不存在：$NODE_BIN"
    exit 1
fi

echo "PM2 路径: $PM2_PATH"
echo "Node.js 路径: $NODE_BIN"

"$NODE_BIN" "$PM2_PATH" -v

# 开启白虎服务
"$NODE_BIN" "$PM2_PATH" start "./baihu server" --name baihu

echo "10秒后开始恢复任务..."
sleep 10

# 从日志中获取密码
DEFAULT_PASSWORD=$(tail -n 100 ~/.pm2/logs/baihu-out.log \
    | grep -oP '密\s*码:\s*\K[^,[:space:]]+' \
    | tail -n 1)

echo "默认用户名: admin"
echo "============重置密码==============="

BHToken=$(
curl -c /tmp/baihu-cookies.txt -s -D - -o /dev/null \
  "http://localhost:${BAIHU_PORT}/api/v1/auth/login" \
  -H 'content-type: application/json' \
  --data-raw "{\"username\":\"admin\",\"password\":\"$DEFAULT_PASSWORD\"}" \
| awk -F'[=;]' '/Set-Cookie: BHToken=/{print $2}'
)

sleep 1

RESET_RESPONSE=$(
  curl -b /tmp/baihu-cookies.txt "http://localhost:${BAIHU_PORT}/api/v1/settings/password" \
  -H 'content-type: application/json' \
  --data-raw "{\"old_password\":\"$DEFAULT_PASSWORD\",\"new_password\":\"$ADMIN_PASSWORD\"}"
)

echo "密码重置请求完成"
echo "$RESET_RESPONSE"

echo "======================写入rclone配置========================"

mkdir -p /app/.cache/baihu/configs/rclone

if [ -n "$RCLONE_CONF" ]; then
    printf '%s' "$RCLONE_CONF" \
        | base64 -d > /app/.cache/baihu/configs/rclone/rclone.conf || exit 1

    export RCLONE_CONFIG="/app/.cache/baihu/configs/rclone/rclone.conf"

    echo "Rclone 配置写入成功"

    echo "##########同步备份############"

    OUTPUT=$(rclone ls "$REMOTE_FOLDER" 2>&1)
    EXIT_CODE=$?

    if [ "$EXIT_CODE" -eq 0 ]; then
        if [ -z "$OUTPUT" ]; then
            echo "初次安装"
        else
            mkdir -p /tmp/baihu-restore

            latest_file=$(rclone lsjson "$REMOTE_FOLDER" \
                | jq -r 'sort_by(.ModTime) | last | .Path')

            rclone copy "$REMOTE_FOLDER/$latest_file" /tmp/baihu-restore

            ./baihu restore "/tmp/baihu-restore/$latest_file"

            rm -rf /tmp/baihu-restore
            "$NODE_BIN" "$PM2_PATH" restart baihu
        fi
    elif echo "$OUTPUT" | grep -q "directory not found"; then
        echo "错误：文件夹不存在"
    else
        echo "错误：$OUTPUT"
    fi

else
    echo "没有检测到Rclone配置信息"
fi

echo "Baihu successful 🎉"

tail -f /dev/null

