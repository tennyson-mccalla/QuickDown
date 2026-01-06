# KaTeX Math Test

## Inline Math

The quadratic formula is $x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$ and Einstein's famous equation is $E = mc^2$.

## Display Math

The Euler's identity:

$$e^{i\pi} + 1 = 0$$

A more complex equation:

$$\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}$$

## Matrix

$$\begin{pmatrix} a & b \\ c & d \end{pmatrix}$$

## Sum and Product

$$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$

$$\prod_{i=1}^{n} i = n!$$

## Regular code (should still work)

```python
def quadratic(a, b, c):
    return (-b + (b**2 - 4*a*c)**0.5) / (2*a)
```
