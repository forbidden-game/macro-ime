#!/usr/bin/env bash
# 等待 zhwiki 下载完成 → 校验 → 自动跑训练管线
set -u
WORK=$HOME/work/omarime-data
BZ=$WORK/downloads/zhwiki-latest.xml.bz2
TARGET=3379207113
REPO=$HOME/work/projects/omarchy_plugins/omarime

echo "[watcher] 等待下载完成..."
while true; do
    size=$(stat -c%s "$BZ" 2>/dev/null || echo 0)
    if [ "$size" -ge "$TARGET" ]; then
        echo "[watcher] 大小达标 ($size)"
        break
    fi
    if ! pgrep -f "curl.*zhwiki" > /dev/null; then
        # 进程没了但大小没到 → 断点续传拉起来
        echo "[watcher] curl 中断于 $size, 重启续传"
        nohup curl -sL -C - -o "$BZ" \
            https://dumps.wikimedia.org/zhwiki/latest/zhwiki-latest-pages-articles.xml.bz2 \
            >> "$WORK/downloads/zhwiki-dl3.log" 2>&1 &
    fi
    sleep 30
done

echo "[watcher] 校验 bz2 完整性..."
if ! bzip2 -t "$BZ" 2>/dev/null; then
    echo "[watcher] bz2 损坏! 删除尾部重下"
    exit 1
fi

echo "[watcher] 启动训练管线 (12核)..."
export KENLM_BIN=$HOME/work/kenlm/build_bin
bash "$REPO/lm/pipeline.sh" 12 > "$WORK/pipeline.log" 2>&1
echo "[watcher] 管线退出码 $? , 日志: $WORK/pipeline.log"
