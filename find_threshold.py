import csv
import json
import re

# Read the log file to extract P(3)+P(4) for the 'app' pipeline
log_path = r"C:\Users\Shardul\.gemini\antigravity-ide\brain\b3fc6bfa-b8c7-42c5-bfa9-e1e969e8875f\.system_generated\tasks\task-2498.log"

results = []
in_app = False
with open(log_path, 'r') as f:
    for line in f:
        line = line.strip()
        if "=== pipeline: app ===" in line:
            in_app = True
            continue
        if "=== pipeline: no_clahe ===" in line:
            in_app = False
            break
            
        if in_app and "true=" in line:
            # Parse line: filename [ probs ] argmax=X P(>=2)=Y true=Z
            # Example: aptos...jpg [ 0.453  0.098  0.316  0.012  0.117] argmax=0 P(>=2)=0.445 true=0
            probs_str = line.split('[')[1].split(']')[0]
            probs = [float(p) for p in probs_str.split()]
            true_grade = int(line.split('true=')[1])
            argmax = int(line.split('argmax=')[1].split()[0])
            
            p_urgent = probs[3] + probs[4]
            results.append({
                'true_grade': true_grade,
                'argmax': argmax,
                'p_urgent': p_urgent
            })

# We want to recover missed urgent cases (True grade 3 or 4, but argmax <= 2)
# without causing too many false positives (True grade < 3, escalated to urgent).
# Since missed urgent cases are ALL Grade 2, maybe we only escalate if argmax == 2?

for t in [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5]:
    recovered = 0
    fp = 0
    for r in results:
        # If argmax < 3 but we escalate:
        if r['argmax'] < 3 and r['p_urgent'] >= t:
            if r['true_grade'] >= 3:
                recovered += 1
            else:
                fp += 1
    
    print(f"t={t:.2f} -> Recovered Grade 3-4: {recovered} | False Positives (True <3 escalated): {fp}")

