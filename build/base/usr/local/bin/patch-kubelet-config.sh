#!/bin/bash
# Patch kubelet config for rootless operation after kubeadm init
if [ -f /var/lib/kubelet/config.yaml ]; then
  sed -i "s/cgroupDriver: systemd/cgroupDriver: cgroupfs/" /var/lib/kubelet/config.yaml
  sed -i "s|cgroupRoot: /kubelet|cgroupRoot: /kubelet.slice|" /var/lib/kubelet/config.yaml
  echo "Kubelet config patched for rootless operation"
fi

