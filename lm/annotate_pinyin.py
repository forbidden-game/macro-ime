#!/usr/bin/env python3
"""omarime 词典源生成 v0 (Spike)

vocab.txt → dict.src.txt (word<TAB>pinyin<TAB>freq)
用 pypinyin 标注无声调拼音; 拼音含非字母或音节数与字数不符的词丢弃。
此文件后续经 libime_pinyindict 编译为 .dict (解码器格词典)。
已知限制: 多音字按最常见读音, Spike 阶段接受少量噪声。
"""
import sys
from pypinyin import lazy_pinyin, Style

def main(vocab, dst):
    kept = dropped = 0
    with open(vocab, encoding='utf-8') as f, open(dst, 'w', encoding='utf-8') as out:
        for line in f:
            word, freq = line.rstrip('\n').split('\t')
            py = lazy_pinyin(word, style=Style.NORMAL, errors='ignore')
            if len(py) != len(word) or not all(p.isalpha() and p.isascii() for p in py):
                dropped += 1
                continue
            out.write(f"{word}\t{' '.join(py)}\t{freq}\n")
            kept += 1
    print(f"dict source: {kept} kept, {dropped} dropped -> {dst}")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
