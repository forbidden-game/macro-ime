#!/usr/bin/env python3
"""Macro IME 分词器 v0 (Spike)

词典驱动的正向最长匹配 (FMM):
  - pyahocorasick 自动机加载词表
  - 未命中汉字回退为单字
  - 多进程并行

输入: clean.txt (每行一句, 纯汉字)
输出: seg.txt   (token 空格分隔, 每行一句)
"""
import sys
import ahocorasick
from multiprocessing import Pool

A = None

def init(vocab_path):
    global A
    A = ahocorasick.Automaton()
    with open(vocab_path, encoding='utf-8') as f:
        for line in f:
            word = line.split('\t')[0].strip()
            if word:
                A.add_word(word, word)
    A.make_automaton()

def fmm(sentence):
    """正向最长匹配。ahocorasick 是按结束位置给命中, 这里用它收集
    每个位置结尾的最长词, 再从左到右贪心。"""
    n = len(sentence)
    # end_at[e] = 以 e 结尾的最长词长
    end_at = {}
    for e, word in A.iter(sentence):
        l = len(word)
        if e not in end_at or l > end_at[e]:
            end_at[e] = l
    out, i = [], 0
    while i < n:
        best = 0
        for e in range(i, min(n, i + 8)):   # 词长<=8, 够用
            if e in end_at:
                l = end_at[e]
                s = e - l + 1
                if s == i and l > best:      # 必须从 i 开始
                    best = l
        if best > 0:
            out.append(sentence[i:i + best])
            i += best
        else:
            out.append(sentence[i])          # 单字回退
            i += 1
    return out

def work(line):
    line = line.strip()
    if not line:
        return ""
    return " ".join(fmm(line))

def process_batch(batch):
    return [work(l) for l in batch]

def main(vocab_path, src, dst, workers=12, batch_lines=500000):
    """流式分批: 每批 batch_lines 行, 内存 O(batch) 而非 O(全文件)"""
    def batches():
        batch = []
        with open(src, encoding='utf-8') as f:
            for line in f:
                batch.append(line)
                if len(batch) >= batch_lines:
                    yield batch
                    batch = []
        if batch:
            yield batch

    total = 0
    with Pool(workers, initializer=init, initargs=(vocab_path,)) as p, \
         open(dst, 'w', encoding='utf-8') as out:
        for results in p.imap(process_batch, batches(), chunksize=1):
            out.write('\n'.join(r for r in results if r) + '\n')
            total += len(results)
    print(f"segmented ~{total} lines -> {dst}")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3],
         workers=int(sys.argv[4]) if len(sys.argv) > 4 else 12)
