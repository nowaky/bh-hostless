
FROM ghcr.io/engigu/baihu:latest

ENV REMOTE_FOLDER="huggingface:baihu"

RUN apt-get update && apt-get install -y \
    jq \
    curl \
    unzip \
    sshpass \
    openssh-client \
    && curl -fsSL https://rclone.org/install.sh | bash \
    && rclone version \
    && ssh -V \
    && sshpass -V \
    && rm -rf /var/lib/apt/lists/*

# 初始化 Node.js 环境
RUN mise use -g node@23.11.1

# ===== 构建阶段预装 PM2 =====
# 使用 Mise 管理的 Node.js 安装最新版 PM2
RUN set -eux; \
    NODE_BIN="$(mise which node)"; \
    NODE_DIR="$(dirname "$NODE_BIN")"; \
    "$NODE_DIR/npm" install -g pm2; \
    "$NODE_DIR/pm2" -v

RUN rclone config -h

# 复制原恢复脚本
COPY ./restore.sh /restore.sh

# Hostless 只读目录适配
# 在镜像构建阶段预先创建软链接
RUN set -eux; \
    mkdir -p /app/.cache/baihu/data; \
    mkdir -p /app/.cache/baihu/configs; \
    mkdir -p /app/.cache/baihu/envs; \
    \
    if [ -d /app/data ] && [ ! -L /app/data ]; then \
        cp -a /app/data/. /app/.cache/baihu/data/; \
    fi; \
    if [ -d /app/configs ] && [ ! -L /app/configs ]; then \
        cp -a /app/configs/. /app/.cache/baihu/configs/; \
    fi; \
    if [ -d /app/envs ] && [ ! -L /app/envs ]; then \
        cp -a /app/envs/. /app/.cache/baihu/envs/; \
    fi

# 替换新版 Baihu 启动函数 ，启动入口修改
RUN cat > /app/hostless-init.sh <<'EOF'
#!/bin/sh
set -eu

mkdir -p /app/.cache/baihu/data
mkdir -p /app/.cache/baihu/configs
mkdir -p /app/.cache/baihu/envs

for name in data configs envs; do
    TARGET="/app/$name"
    DEST="/app/.cache/baihu/$name"

    if [ -L "$TARGET" ]; then
        rm -f "$TARGET"
    elif [ -d "$TARGET" ]; then
        cp -an "$TARGET/." "$DEST/" 2>/dev/null || true
        rmdir "$TARGET" 2>/dev/null || true
    fi

    if [ ! -e "$TARGET" ]; then
        ln -s "$DEST" "$TARGET"
    fi
done
EOF

RUN chmod +x /app/hostless-init.sh \
    && sed -i '2a /app/hostless-init.sh' /app/docker-entrypoint.sh \
    && sed -i 's/^start_baihu_server "\$@"$/sh \/restore.sh/' /app/docker-entrypoint.sh \
    && echo "========== 修改后的 ENTRYPOINT ==========" \
    && tail -n 15 /app/docker-entrypoint.sh \
    && grep -q '^sh /restore.sh$' /app/docker-entrypoint.sh

# Python 环境
RUN mise exec python@3.13.12 -- pip install requests
RUN mise use -g python@3.13.12
