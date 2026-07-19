#!/usr/bin/env python3
"""
Confident-learning data cleaning on the cached BioCLIP embeddings.

Out-of-fold cross-validation gives every TRAIN image a prediction from a model
that never saw it. Images the model confidently assigns to a DIFFERENT class
than their folder label are very likely junk (stumps/bark/landscape) or
mislabels. Drop them, refit the head, and re-score on the untouched testset.
"""
import os
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import cross_val_predict

HERE = os.path.dirname(os.path.abspath(__file__))
z = np.load(os.path.join(HERE, "embeddings_bioclip.npz"), allow_pickle=True)
Xtr, ytr, Xte, yte = z["Xtr"], z["ytr"], z["Xte"], z["yte"]

BAD = {
    "poison_ivy_eastern", "poison_ivy_western",
    "poison_oak_pacific", "poison_oak_atlantic", "poison_sumac",
}

# Out-of-fold probabilities for every training image.
print("cross-validating train set to find noisy labels…")
clf = LogisticRegression(max_iter=2000, C=1.0)
oof = cross_val_predict(clf, Xtr, ytr, cv=5, method="predict_proba")
classes = sorted(set(ytr))
cidx = {c: i for i, c in enumerate(classes)}
true_prob = np.array([oof[i, cidx[y]] for i, y in enumerate(ytr)])
pred = np.array([classes[j] for j in oof.argmax(1)])
pred_prob = oof.max(1)

# Junk = confidently predicted as a DIFFERENT class (disagree & pred_prob high),
# i.e. the model is sure it's something else than its label.
noisy = (pred != ytr) & (pred_prob >= 0.60)
print(f"flagged {noisy.sum()} / {len(ytr)} train images as likely junk/mislabel "
      f"({noisy.mean()*100:.1f}%)")
for c in classes:
    m = (ytr == c)
    print(f"  {c:<22} flagged {int((noisy & m).sum()):>3} / {int(m.sum())}")

keep = ~noisy
Xc, yc = Xtr[keep], ytr[keep]
print(f"\nrefit head on cleaned train ({keep.sum()} imgs)…")
clf2 = LogisticRegression(max_iter=2000, C=1.0)
clf2.fit(Xc, yc)

proba = clf2.predict_proba(Xte)
cl = clf2.classes_
pred_te = cl[proba.argmax(1)]
conf_te = proba.max(1)
out = os.path.join(HERE, "predictions_bioclip_clean.csv")
with open(out, "w") as f:
    f.write("true,pred,confidence\n")
    for t, p, c in zip(yte, pred_te, conf_te):
        f.write(f"{t},{p},{c}\n")
print(f"wrote {out}")
print(f"raw test accuracy after cleaning: {(pred_te == yte).mean()*100:.1f}%")
