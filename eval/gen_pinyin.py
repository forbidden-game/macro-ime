#!/usr/bin/env python3
"""testset.tsv (bucket\tsentence) → eval.tsv (pinyin\tsentence)
用 pypinyin 生成无声调全拼, 保证拼音与期望句严格一致。"""
import sys
from pypinyin import lazy_pinyin, Style

def main(src, dst):
    n = 0
    with open(src, encoding='utf-8') as f, open(dst, 'w', encoding='utf-8') as out:
        next(f)  # header
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) != 2:
                continue
            bucket, sent = parts
            py = ''.join(lazy_pinyin(sent, style=Style.NORMAL))
            out.write(f"{py}\t{sent}\n")
            n += 1
    print(f"{n} eval cases -> {dst}")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
