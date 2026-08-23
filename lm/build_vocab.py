#!/usr/bin/env python3
"""Macro IME 词表构建 v0 (Spike)

从 jieba 词表提取纯汉字词作为分词词库。
过滤规则: 全汉字、长度1-6、词频>=2。
输出: vocab.txt (word<TAB>freq), 按词频降序。
"""
import sys

def is_hanzi(ch):
    return '\u4e00' <= ch <= '\u9fff'

def main(src, dst, min_freq=2, max_len=6):
    kept = 0
    with open(src, encoding='utf-8') as f, open(dst, 'w', encoding='utf-8') as out:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            word, freq = parts[0], int(parts[1])
            if not (1 <= len(word) <= max_len):
                continue
            if freq < min_freq:
                continue
            if not all(is_hanzi(c) for c in word):
                continue
            out.write(f"{word}\t{freq}\n")
            kept += 1
    print(f"vocab: {kept} words -> {dst}")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2],
         min_freq=int(sys.argv[3]) if len(sys.argv) > 3 else 2)
