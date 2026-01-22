#!/usr/bin/env python3
"""
Generate markdown test files of various sizes and complexity for performance testing.
"""

import os
import random
from pathlib import Path

OUTPUT_DIR = Path(__file__).parent.parent / "files"

# Sample content generators
LOREM = """Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris."""

CODE_SAMPLES = {
    "python": '''def fibonacci(n):
    if n <= 1:
        return n
    return fibonacci(n-1) + fibonacci(n-2)

# Calculate first 10 fibonacci numbers
for i in range(10):
    print(f"F({i}) = {fibonacci(i)}")''',

    "javascript": '''async function fetchData(url) {
  try {
    const response = await fetch(url);
    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Error:', error);
  }
}''',

    "swift": '''struct ContentView: View {
    @State private var count = 0

    var body: some View {
        VStack {
            Text("Count: \\(count)")
            Button("Increment") {
                count += 1
            }
        }
    }
}''',

    "rust": '''fn main() {
    let numbers: Vec<i32> = (1..=10).collect();
    let sum: i32 = numbers.iter().sum();
    println!("Sum: {}", sum);
}''',
}

MERMAID_SAMPLES = [
    '''```mermaid
graph TD
    A[Start] --> B{Decision}
    B -->|Yes| C[Action 1]
    B -->|No| D[Action 2]
    C --> E[End]
    D --> E
```''',
    '''```mermaid
sequenceDiagram
    Client->>Server: Request
    Server->>Database: Query
    Database-->>Server: Results
    Server-->>Client: Response
```''',
    '''```mermaid
pie title Distribution
    "A" : 40
    "B" : 30
    "C" : 20
    "D" : 10
```''',
]

MATH_SAMPLES = [
    r"The quadratic formula: $x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$",
    r"Euler's identity: $e^{i\pi} + 1 = 0$",
    r"$$\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$",
    r"The sum: $\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$",
    r"$$\nabla \times \vec{E} = -\frac{\partial \vec{B}}{\partial t}$$",
]


def generate_heading(level, text):
    return f"{'#' * level} {text}\n\n"


def generate_paragraph():
    return f"{LOREM}\n\n"


def generate_list(items=5, ordered=False):
    lines = []
    for i in range(items):
        prefix = f"{i+1}." if ordered else "-"
        lines.append(f"{prefix} Item {i+1}: {LOREM[:50]}")
    return "\n".join(lines) + "\n\n"


def generate_table(rows=5, cols=4):
    lines = []
    header = "| " + " | ".join([f"Column {i+1}" for i in range(cols)]) + " |"
    separator = "| " + " | ".join(["---"] * cols) + " |"
    lines.append(header)
    lines.append(separator)
    for r in range(rows):
        row = "| " + " | ".join([f"Cell {r+1},{c+1}" for c in range(cols)]) + " |"
        lines.append(row)
    return "\n".join(lines) + "\n\n"


def generate_code_block(lang=None):
    if lang is None:
        lang = random.choice(list(CODE_SAMPLES.keys()))
    code = CODE_SAMPLES.get(lang, CODE_SAMPLES["python"])
    return f"```{lang}\n{code}\n```\n\n"


def generate_blockquote():
    return f"> {LOREM[:100]}\n>\n> — Someone Famous\n\n"


def generate_link():
    return f"Check out [this link](https://example.com) for more information.\n\n"


# File generators

def generate_small():
    """~100 lines of plain markdown"""
    content = []
    content.append(generate_heading(1, "Small Test Document"))
    content.append(generate_paragraph())

    for i in range(5):
        content.append(generate_heading(2, f"Section {i+1}"))
        content.append(generate_paragraph())
        content.append(generate_list(3))

    return "".join(content)


def generate_medium():
    """~1000 lines of mixed content"""
    content = []
    content.append(generate_heading(1, "Medium Test Document"))
    content.append(generate_paragraph())

    for i in range(20):
        content.append(generate_heading(2, f"Chapter {i+1}"))
        content.append(generate_paragraph())
        content.append(generate_paragraph())
        content.append(generate_list(5, ordered=(i % 2 == 0)))
        content.append(generate_code_block())
        content.append(generate_table(3, 4))
        content.append(generate_blockquote())
        content.append(generate_link())

    return "".join(content)


def generate_large():
    """~10,000 lines stress test"""
    content = []
    content.append(generate_heading(1, "Large Test Document (10K lines)"))
    content.append(generate_paragraph())

    for i in range(100):
        content.append(generate_heading(2, f"Section {i+1}"))
        for j in range(3):
            content.append(generate_heading(3, f"Subsection {i+1}.{j+1}"))
            content.append(generate_paragraph())
            content.append(generate_paragraph())
            content.append(generate_list(5))
            if j % 2 == 0:
                content.append(generate_code_block())
            if j % 3 == 0:
                content.append(generate_table(5, 5))

    return "".join(content)


def generate_huge():
    """~50,000 lines extreme stress test"""
    content = []
    content.append(generate_heading(1, "Huge Test Document (50K lines)"))

    for i in range(500):
        content.append(generate_heading(2, f"Section {i+1}"))
        for j in range(3):
            content.append(generate_heading(3, f"Subsection {i+1}.{j+1}"))
            content.append(generate_paragraph())
            content.append(generate_paragraph())
            content.append(generate_paragraph())
            content.append(generate_list(7))
            content.append(generate_code_block())

    return "".join(content)


def generate_code_heavy():
    """~500 lines mostly code blocks"""
    content = []
    content.append(generate_heading(1, "Code-Heavy Test Document"))
    content.append("This document tests syntax highlighting performance.\n\n")

    for i in range(50):
        lang = list(CODE_SAMPLES.keys())[i % len(CODE_SAMPLES)]
        content.append(generate_heading(2, f"Example {i+1}: {lang.title()}"))
        content.append(generate_code_block(lang))
        content.append(generate_paragraph())

    return "".join(content)


def generate_mermaid_heavy():
    """~200 lines with many mermaid diagrams"""
    content = []
    content.append(generate_heading(1, "Mermaid-Heavy Test Document"))
    content.append("This document tests mermaid diagram rendering performance.\n\n")

    for i in range(15):
        content.append(generate_heading(2, f"Diagram {i+1}"))
        content.append(generate_paragraph())
        content.append(MERMAID_SAMPLES[i % len(MERMAID_SAMPLES)])
        content.append("\n\n")

    return "".join(content)


def generate_math_heavy():
    """~300 lines with many KaTeX equations"""
    content = []
    content.append(generate_heading(1, "Math-Heavy Test Document"))
    content.append("This document tests KaTeX math rendering performance.\n\n")

    for i in range(50):
        content.append(generate_heading(2, f"Equation Set {i+1}"))
        content.append(generate_paragraph())
        for j in range(3):
            content.append(MATH_SAMPLES[(i + j) % len(MATH_SAMPLES)] + "\n\n")

    return "".join(content)


def generate_mixed_features():
    """~500 lines with all features combined"""
    content = []
    content.append(generate_heading(1, "Mixed Features Test Document"))
    content.append("This document combines all features for comprehensive testing.\n\n")

    content.append(generate_heading(2, "Table of Contents"))
    content.append("- [Code Examples](#code-examples)\n")
    content.append("- [Diagrams](#diagrams)\n")
    content.append("- [Mathematics](#mathematics)\n")
    content.append("- [Tables](#tables)\n\n")

    content.append(generate_heading(2, "Code Examples"))
    for lang in CODE_SAMPLES:
        content.append(generate_heading(3, lang.title()))
        content.append(generate_code_block(lang))

    content.append(generate_heading(2, "Diagrams"))
    for i, diagram in enumerate(MERMAID_SAMPLES):
        content.append(generate_heading(3, f"Diagram {i+1}"))
        content.append(diagram + "\n\n")

    content.append(generate_heading(2, "Mathematics"))
    for eq in MATH_SAMPLES:
        content.append(eq + "\n\n")

    content.append(generate_heading(2, "Tables"))
    content.append(generate_table(10, 6))

    content.append(generate_heading(2, "Lists"))
    content.append(generate_list(10, ordered=True))
    content.append(generate_list(10, ordered=False))

    return "".join(content)


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    files = {
        "small.md": generate_small,
        "medium.md": generate_medium,
        "large.md": generate_large,
        "huge.md": generate_huge,
        "code-heavy.md": generate_code_heavy,
        "mermaid-heavy.md": generate_mermaid_heavy,
        "math-heavy.md": generate_math_heavy,
        "mixed-features.md": generate_mixed_features,
    }

    print("Generating test files...")
    for filename, generator in files.items():
        filepath = OUTPUT_DIR / filename
        content = generator()
        filepath.write_text(content)
        lines = content.count('\n')
        size_kb = len(content.encode()) / 1024
        print(f"  ✓ {filename}: {lines:,} lines, {size_kb:.1f} KB")

    print(f"\nTest files written to: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
