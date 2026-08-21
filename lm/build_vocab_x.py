#!/usr/bin/env python3
"""E3 词表: sc.dict ∩ jieba高频词 交集 + 全部单字
对齐(解码器能提的) × 粒度合理(jieba频次门槛筛掉生僻长词)"""
import sys

def main(dict_text, jieba_dict, dst, min_jieba_freq=20, max_len=6):
    jieba_freq = {}
    with open(jieba_dict, encoding='utf-8') as f:
        for line in f:
            p = line.split()
            if len(p) >= 2 and all('\u4e00' <= c <= '\u9fff' for c in p[0]):
                try:
                    jieba_freq[p[0]] = int(p[1])
                except ValueError:
                    pass

    kept_multi, dropped = 0, 0
    singles = set()
    with open(dict_text, encoding='utf-8') as fin, \
         open(dst, 'w', encoding='utf-8') as out:
        for line in fin:
            parts = line.split()
            if not parts:
                continue
            w = parts[0]
            if not all('\u4e00' <= c <= '\u9fff' for c in w):
                continue
            if len(w) == 1:
                singles.add(w)
            elif w in jieba_freq and jieba_freq[w] >= min_jieba_freq and len(w) <= max_len:
                out.write(f"{w}\t{jieba_freq[w]}\n")
                kept_multi += 1
            else:
                dropped += 1
        for c in singles:
            out.write(f"{c}\t1\n")
    print(f"E3 vocab: {kept_multi} 多字词 + {len(singles)} 单字, 丢弃 {dropped} -> {dst}")

if __name__ == '__main__':
    main(*sys.argv[1:])
