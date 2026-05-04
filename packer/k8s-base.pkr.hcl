packer {
  required_plugins {
    vagrant = {
      version = ">= 1.1.5"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

variable "source_box" {
  type    = string
  default = "bento/ubuntu-24.04"
}

variable "provider" {
  type    = string
  default = "libvirt"
}

variable "box_output" {
  type    = string
  default = ".bake/boxes/ffreis-k8s-base-ubuntu24.box"
}

variable "kube_version" {
  type    = string
  default = "1.30.6-1.1"
}

variable "kube_channel" {
  type    = string
  default = "v1.30"
}

variable "containerd_version" {
  type    = string
  default = "1.7.28-0ubuntu1~24.04.2"
}

variable "pause_image" {
  type    = string
  default = "registry.k8s.io/pause:3.9"
}

variable "apt_proxy" {
  type    = string
  default = ""
}

source "vagrant" "ubuntu" {
  source_path = var.source_box
  provider    = var.provider
  communicator = "ssh"
}

build {
  name    = "k8s-base"
  sources = ["source.vagrant.ubuntu"]

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "KUBE_VERSION=${var.kube_version}",
      "KUBE_CHANNEL=${var.kube_channel}",
      "KUBE_CONTAINERD_VERSION=${var.containerd_version}",
      "KUBE_PAUSE_IMAGE=${var.pause_image}",
      "KUBE_APT_PROXY=${var.apt_proxy}"
    ]
    inline = [
      "set -euo pipefail",
      "sudo modprobe overlay || true",
      "sudo modprobe br_netfilter || true",
      "cat <<'CFG' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null\noverlay\nbr_netfilter\nCFG",
      "cat <<'CFG' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null\nnet.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\nCFG",
      "sudo sysctl --system >/dev/null",
      "sudo swapoff -a || true",
      "sudo sed -ri '/\\sswap\\s/s/^#?/#/' /etc/fstab",
      "if [ -n \"${KUBE_APT_PROXY}\" ]; then printf 'Acquire::http::Proxy \"%s\";\\nAcquire::https::Proxy \"%s\";\\n' \"${KUBE_APT_PROXY}\" \"${KUBE_APT_PROXY}\" | sudo tee /etc/apt/apt.conf.d/95proxy >/dev/null; else sudo rm -f /etc/apt/apt.conf.d/95proxy; fi",
      "sudo apt-get update -y -o APT::Update::Error-Mode=any",
      "sudo apt-get install -y apt-transport-https ca-certificates curl gpg jq",
      "sudo install -m 0755 -d /etc/apt/keyrings",
      "tmp_key=\"$(mktemp)\"",
      "curl -fsSL --connect-timeout 10 --max-time 60 \"https://pkgs.k8s.io/core:/stable:/${KUBE_CHANNEL}/deb/Release.key\" -o \"${tmp_key}\"",
      "sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \"${tmp_key}\"",
      "rm -f \"${tmp_key}\"",
      "echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_CHANNEL}/deb/ /\" | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null",
      "sudo apt-get update -y -o APT::Update::Error-Mode=any",
      "if [ -n \"${KUBE_CONTAINERD_VERSION}\" ]; then ctr_pkg=\"containerd=${KUBE_CONTAINERD_VERSION}\"; else ctr_pkg=\"containerd\"; fi",
      "sudo apt-get install -y \"${ctr_pkg}\" \"kubelet=${KUBE_VERSION}\" \"kubeadm=${KUBE_VERSION}\" \"kubectl=${KUBE_VERSION}\"",
      "sudo apt-mark hold kubelet kubeadm kubectl",
      "sudo mkdir -p /etc/containerd",
      "sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null",
      "esc_pause=\"$(printf '%s' \"${KUBE_PAUSE_IMAGE}\" | sed -e 's/[&\\\\#]/\\\\&/g')\"",
      "sudo sed -Ei \"s#^([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*).*$#\\1\\\"${esc_pause}\\\"#\" /etc/containerd/config.toml",
      "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable containerd kubelet",
      "sudo systemctl restart containerd kubelet"
    ]
  }

  post-processor "vagrant" {
    output = var.box_output
  }
}
