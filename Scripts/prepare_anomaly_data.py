"""Seeded, disjoint simulated households; no user data."""
import csv, json, math, random, statistics
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
CATEGORIES = ['Groceries', 'Utilities', 'Transport', 'Home', 'Health', 'Other']

def features(amount, category, history):
    same = [x[1] for x in history if x[0] == category]
    mean = statistics.mean(same)
    deviation = max(statistics.pstdev(same), mean * .1)
    return dict(category=category, amountRatio=min(amount/mean, 50),
                householdRatio=min(amount/statistics.mean(x[1] for x in history), 50),
                deviation=min(max((amount-mean)/deviation, -50), 50),
                categoryFrequency=len(same)/len(history))

for split, seed, households in [('train', 7241, 400), ('validation', 8342, 100), ('test', 9453, 100)]:
    rng = random.Random(seed)
    rows=[]
    for household in range(households):
        scale=rng.uniform(100, 15000)
        means=[scale*rng.uniform(.2, 3) for _ in CATEGORIES]
        spreads=[rng.uniform(.12, .65) for _ in CATEGORIES]
        history=[(cat, rng.lognormvariate(math.log(means[i]), spreads[i]))
                 for i,cat in enumerate(CATEGORIES) for _ in range(rng.randint(8, 30))]
        for _ in range(20):
            i=rng.randrange(6); cat=CATEGORIES[i]
            # Labels describe the generating event, not a threshold applied to features.
            unusual=rng.random()<.15
            amount=rng.lognormvariate(math.log(means[i]), spreads[i])
            if unusual: amount*=rng.uniform(2.8, 9)  # injected unexpected expense
            elif rng.random()<.08: amount*=rng.uniform(1.5, 3) # legitimate large purchase, overlaps positives
            row=features(amount, cat, history)
            row['label']='unusual' if unusual else 'typical'
            rows.append(row)
    directory=ROOT/'ML'/'Data'; directory.mkdir(exist_ok=True, parents=True)
    with (directory/f'anomaly-{split}.csv').open('w') as f:
        writer=csv.DictWriter(f, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    (directory/f'anomaly-{split}.json').write_text(json.dumps(rows))
    print(split, len(rows))
