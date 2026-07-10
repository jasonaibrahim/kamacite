#!/usr/bin/env python3
"""Deterministic (seeded) markdown corpus generator.

Produces LLM-output-shaped markdown — prose with inline styling, fenced code blocks,
GFM tables, nested/task lists, blockquotes, links — in realistic ratios.

usage: gen_corpus.py typical|large|huge [out-path]
"""
import random
import sys

PRESETS = {
    "typical": ("bench/corpus/typical-llm.md", 50_000),
    "large": ("bench/corpus/large.md", 5_000_000),
    "huge": ("bench/corpus/huge.md", 100_000_000),
}

WORDS = (
    "engine renderer viewport glyph atlas metal swift parser layout block inline "
    "document scroll anchor theme token font shaping pipeline buffer frame present "
    "latency budget measure profile launch window markdown heading table quote code "
    "fence source span offset cache evict page texture quad instance draw call "
    "baseline cluster estimate exact commit signpost drawable present handler warm "
    "cold resident process bundle helper symlink recent panel viewer selection copy"
).split()

CODE_SNIPPETS = {
    "swift": [
        "let start = CACurrentMediaTime()",
        "func layout(_ block: FlatBlock) -> BlockLayout {",
        "    return store.exact[block.id] ?? compute(block)",
        "}",
    ],
    "python": [
        "def p95(values):",
        "    values = sorted(values)",
        "    return values[round(0.95 * (len(values) - 1))]",
    ],
    "sh": [
        "make bench",
        "hyperfine './vw --bench corpus.md'",
    ],
}


def words(rng, n):
    return " ".join(rng.choice(WORDS) for _ in range(n))


def sentence(rng):
    n = rng.randint(8, 18)
    picked = [rng.choice(WORDS) for _ in range(n)]
    i = rng.randrange(n)
    roll = rng.random()
    if roll < 0.15:
        picked[i] = f"**{picked[i]}**"
    elif roll < 0.25:
        picked[i] = f"`{picked[i]}`"
    elif roll < 0.30:
        picked[i] = f"*{picked[i]}*"
    elif roll < 0.33:
        picked[i] = f"[{picked[i]}](https://example.com/{picked[i]})"
    text = " ".join(picked)
    return text[0].upper() + text[1:] + "."


def paragraph(rng):
    return " ".join(sentence(rng) for _ in range(rng.randint(2, 5)))


def heading(rng, level):
    return "#" * level + " " + words(rng, rng.randint(2, 6)).title()


def bullet_list(rng):
    lines = []
    for _ in range(rng.randint(3, 7)):
        lines.append(f"- {sentence(rng)}")
        if rng.random() < 0.3:
            lines.append(f"  - {sentence(rng)}")
    return "\n".join(lines)


def ordered_list(rng):
    return "\n".join(f"{i}. {sentence(rng)}" for i in range(1, rng.randint(4, 8)))


def task_list(rng):
    return "\n".join(
        f"- [{'x' if rng.random() < 0.5 else ' '}] {sentence(rng)}"
        for _ in range(rng.randint(3, 6))
    )


def code_block(rng):
    lang = rng.choice(list(CODE_SNIPPETS))
    comment = "//" if lang == "swift" else "#"
    body = list(CODE_SNIPPETS[lang])
    for _ in range(rng.randint(1, 6)):
        body.append(f"{comment} {words(rng, rng.randint(3, 8))}")
    return f"```{lang}\n" + "\n".join(body) + "\n```"


def table(rng):
    cols = rng.randint(3, 5)
    header = "| " + " | ".join(words(rng, 1).title() for _ in range(cols)) + " |"
    sep = "|" + "|".join(rng.choice([" --- ", " :--- ", " ---: ", " :---: "]) for _ in range(cols)) + "|"
    rows = [
        "| " + " | ".join(words(rng, rng.randint(1, 3)) for _ in range(cols)) + " |"
        for _ in range(rng.randint(3, 8))
    ]
    return "\n".join([header, sep] + rows)


def quote(rng):
    return "\n".join("> " + sentence(rng) for _ in range(rng.randint(1, 3)))


BLOCKS = [
    (paragraph, 30),
    (code_block, 20),
    (bullet_list, 10),
    (table, 8),
    (quote, 8),
    (task_list, 6),
    (ordered_list, 6),
    (lambda rng: heading(rng, 3), 8),
    (lambda rng: "---", 2),
]


def generate(target_bytes, seed=42):
    rng = random.Random(seed)
    parts = [heading(rng, 1), paragraph(rng)]
    size = sum(len(p) for p in parts)
    makers = [maker for maker, _ in BLOCKS]
    weights = [weight for _, weight in BLOCKS]
    while size < target_bytes:
        section = [heading(rng, 2), paragraph(rng)]
        for maker in rng.choices(makers, weights=weights, k=rng.randint(2, 5)):
            section.append(maker(rng))
        parts.extend(section)
        size += sum(len(p) + 2 for p in section)
    return "\n\n".join(parts) + "\n"


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in PRESETS:
        sys.exit(f"usage: gen_corpus.py {'|'.join(PRESETS)} [out-path]")
    default_path, target = PRESETS[sys.argv[1]]
    path = sys.argv[2] if len(sys.argv) > 2 else default_path
    content = generate(target)
    with open(path, "w") as fh:
        fh.write(content)
    print(f"{path}: {len(content.encode()):,} bytes")


if __name__ == "__main__":
    main()
