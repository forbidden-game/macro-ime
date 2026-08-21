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
NON_HANZI = re.compile(r'[^\u4e00-\u9fff]+')
DOC_TAG = re.compile(r'</?doc[^>]*>')

def clean_line(line):
    line = DOC_TAG.sub('', line)
    if len(line) < 4:
        return []
    s = cc.convert(line)
    # 每段非汉字(标点/数字/英文)都变成切分边界,
    # 同时兼容全角/半角标点 —— 否则半角标点长段落会被整段丢弃
    s = NON_HANZI.sub('\n', s)
    out = []
    for sent in s.split('\n'):
        sent = sent.strip()
        # 最短 4 字: 避免残留碎片
        if 4 <= len(sent) <= 100:
            out.append(sent)
    return out

def work(args):
    """流式处理: 逐行读写, 内存 O(1), 不做跨行去重
    (重复句对 LM 等于天然频次加权, 无害; 全局去重交给 sort -u)"""
    path, outpath = args
    n = 0
    with open(path, encoding='utf-8', errors='ignore') as f, \
         open(outpath, 'w', encoding='utf-8') as out:
        for line in f:
            for s in clean_line(line):
                out.write(s + '\n')
                n += 1
    return n

def main(indir, dst, workers=12):
    files = sorted(glob.glob(f"{indir}/**/wiki_*", recursive=True))
    import os, tempfile
    tmpdir = tempfile.mkdtemp(prefix='omarime-clean-')
    jobs = [(p, os.path.join(tmpdir, f"part{i:04d}")) for i, p in enumerate(files)]
    with Pool(workers) as p:
        counts = p.map(work, jobs)
    # 拼接各部分 (不去重; 如需去重由调用方 sort -u 完成)
    total = sum(counts)
    with open(dst, 'wb') as out:
        for _, part in jobs:
            with open(part, 'rb') as f:
                while True:
                    buf = f.read(1 << 20)
                    if not buf:
                        break
                    out.write(buf)
            os.remove(part)
    os.rmdir(tmpdir)
    print(f"clean sentences: {total} -> {dst}")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 12)
