#!/usr/bin/env bash
# Macro IME LM 训练管线 v0 (Spike) — zhwiki 单源
# 用法: ./pipeline.sh [12]   参数=并行核数
set -euo pipefail

WORK=${WORK:-$HOME/work/macro-ime-data}
REPO=$(cd "$(dirname "$0")/.." && pwd)
PY=$HOME/work/macro-ime-venv/bin/python3
N=${1:-12}
KENLM_BIN=${KENLM_BIN:-$WORK/kenlm/build/bin}

mkdir -p "$WORK"/{wiki,seg}

echo "== [1/6] 解压 zhwiki dump =="
BZ=$WORK/downloads/zhwiki-latest.xml.bz2
[ -f "$BZ" ] || { echo "缺 $BZ"; exit 1; }
if [ ! -f "$WORK/downloads/zhwiki-latest-pages-articles.xml" ]; then
    bunzip2 -kc "$BZ" > "$WORK/downloads/zhwiki-latest-pages-articles.xml"
fi
ls -lh "$WORK/downloads/zhwiki-latest-pages-articles.xml"

echo "== [2/6] wikiextractor 抽正文 =="
if [ ! -d "$WORK/wiki/AA" ]; then
    "$PY" -m wikiextractor.WikiExtractor "$WORK/downloads/zhwiki-latest-pages-articles.xml" \
        -o "$WORK/wiki" --processes "$N" -q
fi
du -sh "$WORK/wiki"

echo "== [3/6] 清洗 =="
"$PY" "$REPO/lm/clean_wiki.py" "$WORK/wiki" "$WORK/clean.txt" "$N"
wc -l "$WORK/clean.txt"; du -sh "$WORK/clean.txt"

echo "== [4/6] 词表 + 分词 =="
JIEBA_DICT=$("$PY" -c "import jieba,os;print(os.path.join(os.path.dirname(jieba.__file__),'dict.txt'))")
"$PY" "$REPO/lm/build_vocab.py" "$JIEBA_DICT" "$WORK/vocab.txt"
"$PY" "$REPO/lm/tokenize.py" "$WORK/vocab.txt" "$WORK/clean.txt" "$WORK/seg/seg.txt" "$N"
du -sh "$WORK/seg/seg.txt"

echo "== [5/6] kenlm 训练 trigram =="
"$KENLM_BIN/lmplz" -o 3 -S 60% --text "$WORK/seg/seg.txt" --arpa "$WORK/spike.arpa" \
    2>&1 | tail -5
ls -lh "$WORK/spike.arpa"

echo "== [6/6] 转换为 libime 格式 (官方同款参数) =="
"$KENLM_BIN/build_binary" -s -a 22 -q 4 trie "$WORK/spike.arpa" "$WORK/macro-ime.lm.bin"
ls -lh "$WORK/macro-ime.lm.bin"

echo "DONE: $WORK/macro-ime.lm.bin"
