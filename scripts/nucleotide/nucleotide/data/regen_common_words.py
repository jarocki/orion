"""Regenerate common-words.txt from the wordfreq package.

Run: python -m nucleotide.data.regen_common_words
Requires: pip install wordfreq
"""
from __future__ import annotations

import importlib.metadata as im
import re
from pathlib import Path

ZIPF_MIN = 3.0


def main() -> None:
    from wordfreq import top_n_list, zipf_frequency

    ver = im.version("wordfreq")
    words = sorted(
        w
        for w in top_n_list("en", 200000, wordlist="best")
        if zipf_frequency(w, "en") >= ZIPF_MIN and re.fullmatch(r"[a-z]+", w)
    )
    out = Path(__file__).with_name("common-words.txt")
    out.write_text(
        f"# English words with Zipf frequency >= {ZIPF_MIN} (>= 1 per million tokens),\n"
        f"# alphabetic only, generated from wordfreq {ver} (wordlist='best', lang='en').\n"
        "# Regenerate: python -m nucleotide.data.regen_common_words\n"
        + "\n".join(words)
        + "\n"
    )
    print(f"wrote {len(words)} words to {out}")


if __name__ == "__main__":
    main()
