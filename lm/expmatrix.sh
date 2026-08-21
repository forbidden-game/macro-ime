#!/usr/bin/env bash
# E7/E8 实验矩阵: 等下载 → 训练 → 评测 → 汇总
set -e
cd $HOME/work/omarime-data
export KENLM_BIN=$HOME/work/kenlm/build_bin
export PY=$HOME/work/omarime-venv/bin/python3
export REPO=$HOME/work/projects/omarchy_plugins/omarime
export TMPDIR=$HOME/work/omarime-data/ktmp

echo "[wait] 等待 40 片下载..."
while ! grep -q CWT2_40_DONE downloads/cwt2-dl2.log 2>/dev/null; do sleep 60; done
echo "[wait] 下载完成"

echo "[E7-1] 清洗新增 CWT2"
$PY - << 'PYEOF'
import pyarrow.parquet as pq, glob, os
os.makedirs("cwt2in2/AA", exist_ok=True)
out = open("cwt2in2/AA/wiki_00", "w", encoding="utf-8")
n = 0
for p in sorted(glob.glob("downloads/cwt2-hq-0*.parquet")):  # 000008..000047 全部
    t = pq.read_table(p).to_pydict()
    for text, q, tox in zip(t["text"], t["quality_score"], [d["score"] for d in t["toxicity"]]):
        if q >= 0.85 and tox < 0.5:
            out.write(text.replace("\n", " ") + "\n")
            n += 1
out.close()
print("new cwt2 docs:", n)
PYEOF
$PY $REPO/lm/clean_wiki.py cwt2in2 clean-cwt2b.txt 12
wc -l clean-cwt2b.txt

echo "[E7-2] 组装+分词"
cat clean-wiki2.txt clean-subs2.txt clean-voyage2.txt clean-news2.txt clean-cwt22.txt clean-cwt2b.txt > clean-e7.txt
wc -l clean-e7.txt
$PY $REPO/lm/tokenize.py vocab_sc.txt clean-e7.txt seg_e7.txt 12

echo "[E7-3] 训练 (prune 0 0 1)"
$KENLM_BIN/lmplz -o 3 -S 70% --prune 0 0 1 --text seg_e7.txt --arpa e7.arpa 2>&1 | tail -1
$KENLM_BIN/build_binary -s -a 22 -q 4 trie e7.arpa omarime-e7.lm.bin 2>&1 | tail -1

echo "[E7-4] 评测"
/tmp/omarime-eval /usr/share/libime/sc.dict omarime-e7.lm.bin /tmp/eval-big.tsv 2>/dev/null | grep -E '^(PASS|FAIL)' > e7-raw.txt
awk -F'\t' '{tot++; if($1=="FAIL") f++} END{printf "E7 TOTAL P@1 = %.1f%% (%d句)\n", (tot-f)*100/tot, tot}' e7-raw.txt

echo "[E8] 不剪枝对照 (E6语料)"
$KENLM_BIN/lmplz -o 3 -S 70% --text seg_e6.txt --arpa e6np.arpa 2>&1 | tail -1
$KENLM_BIN/build_binary -s -a 22 -q 4 trie e6np.arpa omarime-e6np.lm.bin 2>&1 | tail -1
/tmp/omarime-eval /usr/share/libime/sc.dict omarime-e6np.lm.bin /tmp/eval-big.tsv 2>/dev/null | grep -E '^(PASS|FAIL)' > e6np-raw.txt
awk -F'\t' '{tot++; if($1=="FAIL") f++} END{printf "E6np TOTAL P@1 = %.1f%% (%d句)\n", (tot-f)*100/tot, tot}' e6np-raw.txt

rm -f e7.arpa e6np.arpa
echo DONE_EXPMATRIX
