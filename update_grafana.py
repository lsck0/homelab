import urllib.request
import json
import os

# Download a popular Proxmox node exporter dashboard from Grafana (e.g. Node Exporter Full - ID 1860)
# Actually, the user asked for "metrics about proxmox", they could mean the prometheus-pve-exporter, or just node-exporter on the Proxmox host.
# Looking at prometheus scrape configs, it scrapes "192.168.178.200:9100" which is Proxmox's node-exporter.
# So a standard Node Exporter dashboard would work for Proxmox metrics (CPU, RAM, Disk).
# I'll download Dashboard ID 1860 (Node Exporter Full)
url = "https://grafana.com/api/dashboards/1860/revisions/37/download"
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req) as response:
        dashboard_json = response.read().decode('utf-8')
    
    os.makedirs('src/instances/dashboards', exist_ok=True)
    with open('src/instances/dashboards/node-exporter.json', 'w') as f:
        f.write(dashboard_json)
    print("Downloaded dashboard to src/instances/dashboards/node-exporter.json")
except Exception as e:
    print("Error:", e)

