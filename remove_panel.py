import json

with open('grafana-dashboard.json', 'r') as f:
    d = json.load(f)

d['panels'] = [p for p in d['panels'] if p.get('title') != 'Candidate SNI Latency Trend (Direct)']

with open('grafana-dashboard.json', 'w') as f:
    json.dump(d, f, indent=2)
