#!/usr/bin/env python3
"""omarime 语料清洗 v0 (Spike)

输入: wikiextractor 产出的 AA/wiki_00 ... 文本文件
处理: 去<doc>标签 → 繁转简 → 按标点切句 → 保留高汉字占比句 → 去重
输出: clean.txt (每行一句纯汉字)
"""
import sys, re, glob
from multiprocessing import Pool
from opencc import OpenCC

cc = OpenCC('t2s')
SENT_SPLIT = re.compile(r'[。！？；\n]')
HANZI = re.compile(r'[\u4e00-\u9fff]')
NON_HANZI = re.compile(r'[^\u4e00-\u9fff]+')
DOC_TAG = re.compile(r'</?doc[^>]*>')

def clean_line(line):
    line = DOC_TAG.sub('', line)
    if len(line) < 4:
        return []
    s = cc.convert(line)
    s = NON_HANZI.sub('', s)          # Spike: 只保留汉字, 其余切断
    out = []
    for sent in SENT_SPLIT.split(s):
        sent = sent.strip()
        # 最短 4 字: 避免数字剥离后残留 "年是了" 类碎片
        if 4 <= len(sent) <= 100:
            out.append(sent)
    return out

def work(path):
    seen = set()
    with open(path, encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    sents = []
    for ln in lines:
        for s in clean_line(ln):
            if s not in seen:
                seen.add(s)
                sents.append(s)
    return sents

def main(indir, dst, workers=12):
    files = sorted(glob.glob(f"{indir}/**/wiki_*", recursive=True))
    with Pool(workers) as p:
        chunks = p.map(work, files)
    total, seen = 0, set()
    with open(dst, 'w', encoding='utf-8') as out:
        for sents in chunks:
            for s in sents:
                if s not in seen:
                    seen.add(s)
                    out.write(s + '\n')
                    total += 1
    print(f"clean sentences: {total} -> {dst}")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 12)
