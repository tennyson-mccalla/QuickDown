---
title: Gradient Descent and Cross-Entropy — Study Notes
course: ML 4803
date: 2026-04-10
---

# Gradient Descent and Cross-Entropy

These notes cover the core update rule for gradient descent and the derivation of cross-entropy loss for multi-class classification.

## The update rule

Given a differentiable loss function $L(\theta)$, gradient descent updates parameters by stepping against the gradient:

$$\theta_{t+1} = \theta_t - \eta \, \nabla_\theta L(\theta_t)$$

where $\eta$ is the learning rate. The intuition: the gradient points toward the steepest *increase* in loss, so moving the opposite direction decreases loss locally.

## Cross-entropy for classification

For a $K$-class problem with one-hot targets $y$ and predicted probabilities $\hat{y} = \text{softmax}(z)$, the cross-entropy loss is:

$$L_{\text{CE}} = -\sum_{k=1}^{K} y_k \log \hat{y}_k$$

Because $y$ is one-hot, only the term for the correct class survives, simplifying to $-\log \hat{y}_{k^\star}$ where $k^\star$ is the true class index.

## The softmax Jacobian (the useful trick)

The reason cross-entropy pairs so cleanly with softmax is that the gradient of the loss with respect to the pre-softmax logits collapses to:

$$\frac{\partial L_{\text{CE}}}{\partial z_k} = \hat{y}_k - y_k$$

No Jacobian cancellation, no numerical gymnastics — the error signal is just "predicted minus target." This is what makes the backward pass through a softmax + cross-entropy layer fast and numerically stable.

## Implementation sketch

```python
import numpy as np

def softmax(z):
    z = z - z.max(axis=-1, keepdims=True)   # numerical stability
    e = np.exp(z)
    return e / e.sum(axis=-1, keepdims=True)

def cross_entropy(logits, targets):
    probs = softmax(logits)
    return -np.log(probs[np.arange(len(targets)), targets]).mean()

def grad_logits(logits, targets):
    probs = softmax(logits)
    grad = probs.copy()
    grad[np.arange(len(targets)), targets] -= 1
    return grad / len(targets)
```

## Common gotchas

| Gotcha | Why it bites | Fix |
|--------|--------------|-----|
| Computing `log(softmax(z))` naïvely | Overflow when logits are large | Use `log_softmax` with the max-shift trick |
| Forgetting to average over the batch | Gradient magnitude scales with batch size | Divide by `N` in the loss |
| Mixing one-hot and index targets | Silent shape mismatch | Pick one convention and stick to it |

## What to review next

Momentum, Adam, and why learning-rate warmup matters for transformers. Leave that for the next session.
