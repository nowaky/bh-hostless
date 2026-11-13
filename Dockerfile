
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
    PM2_PATH="$("$NODE_DIR/npm" root -g)/pm2/bin/pm2"; \
    test -f "$PM2_PATH"; \
    "$NODE_DIR/node" "$PM2_PATH" -v; \
    printf '%s\n' "$PM2_PATH" > /root/pm2-path

RUN rclone config -h

# 复制原恢复脚本
COPY ./restore.sh /restore.sh

# Hostless 只读目录适配
# 临时跟踪入口脚本执行过程，定位软链接创建来源
RUN set -eux; \
    sed -i '2a set -x' /app/docker-entrypoint.sh; \
    sed -i '2a set -x' /app/docker-entrypoint-common.sh; \
    echo "========== 检查 /app/data 相关命令 =========="; \
    grep -RnE 'ln .*(/app/data|/app/configs|/app/envs)' \
        /app /usr/local/bin /etc /usr/bin 2>/dev/null || true

RUN echo "========== 搜索所有 /app/data 软链接操作 ==========" \
    && grep -RnE 'ln .*(/app/data|/app/configs|/app/envs)' \
       /app /usr/local/bin /etc /usr/bin 2>/dev/null | head -n 100 || true

RUN echo "========== 检查所有软链接操作 ==========" \
    && grep -RnE 'ln .*(/app/data|/app/configs|/app/envs|/usr/local/bin/baihu)' \
       /app/docker-entrypoint.sh \
       /app/docker-entrypoint-common.sh \
       /app/hostless-init.sh \
       /restore.sh 2>/dev/null || true

# Hostless 只读目录适配
# 在镜像构建阶段预先创建软链接
RUN set -eux; \
    mkdir -p /app/.cache/baihu/data; \
    mkdir -p /app/.cache/baihu/configs; \
    mkdir -p /app/.cache/baihu/envs; \
    \
    if [ -d /app/data ] && [ ! -L /app/data ]; then \
        cp -a /app/data/. /app/.cache/baihu/data/; \
        rm -rf /app/data; \
    fi; \
    if [ -d /app/configs ] && [ ! -L /app/configs ]; then \
        cp -a /app/configs/. /app/.cache/baihu/configs/; \
        rm -rf /app/configs; \
    fi; \
    if [ -d /app/envs ] && [ ! -L /app/envs ]; then \
        cp -a /app/envs/. /app/.cache/baihu/envs/; \
        rm -rf /app/envs; \
    fi; \
    ln -sfn /app/.cache/baihu/data /app/data; \
    ln -sfn /app/.cache/baihu/configs /app/configs; \
    ln -sfn /app/.cache/baihu/envs /app/envs

# Hostless 只读目录适配
# 容器启动时仅初始化软链接目标目录，不修改软链接
RUN cat > /app/hostless-init.sh <<'EOF'
#!/bin/sh
set -eu

mkdir -p /app/.cache/baihu/data
mkdir -p /app/.cache/baihu/configs
mkdir -p /app/.cache/baihu/envs
EOF

RUN chmod +x /app/hostless-init.sh \
    && sed -i '2a /app/hostless-init.sh' /app/docker-entrypoint.sh

# Hostless 只读目录适配
# 跳过只读系统目录中的全局 CLI 软链接注册
RUN set -eux; \
    sed -i '/ln -sf \/app\/baihu \/usr\/local\/bin\/baihu/d' /app/docker-entrypoint-common.sh; \
    if grep -q 'ln -sf /app/baihu /usr/local/bin/baihu' /app/docker-entrypoint-common.sh; then \
        echo "错误：CLI 注册补丁未生效"; \
        exit 1; \
    fi
    
# 替换新版 Baihu 启动函数 ，启动入口修改
RUN sed -i 's/^start_baihu_server "\$@"$/sh \/restore.sh/' /app/docker-entrypoint.sh \
    && echo "========== 修改后的 ENTRYPOINT ==========" \
    && tail -n 15 /app/docker-entrypoint.sh \
    && grep -q '^sh /restore.sh$' /app/docker-entrypoint.sh

# Python 环境
RUN mise exec python@3.13.12 -- pip install requests
RUN mise use -g python@3.13.12
