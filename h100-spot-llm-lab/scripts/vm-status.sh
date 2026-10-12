#!/bin/bash
# Compact stack status, run on the VM:  scripts/vm-run.sh scripts/vm-status.sh
cd /opt/llm-self-hosting || {
  echo "ERROR: deployment directory /opt/llm-self-hosting does not exist" >&2
  exit 1
}
echo "compose-up unit: $(systemctl is-active llm-compose-up 2>/dev/null)"
echo "models on disk: $(du -sh /data/models 2>/dev/null | cut -f1)"
docker ps -a --format '{{.Names}}: {{.Status}}'
echo "--- compose-up log"
tail -n 3 /var/log/llm-compose-up.log 2>/dev/null | cut -c1-200
echo "--- model log"
docker logs --tail 5 llm-model 2>&1 | cut -c1-240
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader
