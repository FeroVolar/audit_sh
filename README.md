# Server Audit Script (via Ansible)

This repository provides a **bash script** that automates collecting system information from a remote Linux server over SSH using **Ansible**.

## ✨ Features
- Works with any server reachable as `username@host`  
  (supports `-p <port>` and `-i <ssh_key>` options).  
- Collects and stores:
  - **System facts** (OS, kernel, CPU, RAM, networking, mounts, etc.)
  - **Installed packages** (`package_facts`, `dpkg -l`, `rpm -qa`)
  - **Services** (registered + currently running)
  - **Open ports** (`ss -tulpn`)
  - **Disk and filesystem info** (`lsblk`, `df -h`)
  - **Top processes** by CPU and memory
  - **Key configuration files** (SSH, nginx, apache, fstab, hosts, resolv.conf, …)
- Results are saved in a timestamped folder:

- Output includes both JSON and plain text for easy review or further processing.

## 📦 Requirements
- Control machine (where you run the script):
- [Ansible](https://docs.ansible.com/) installed  
- SSH access to the target server (key-based authentication recommended)
- Target machine: any modern Linux distribution

## 🚀 Usage
```bash
# Basic usage
./audit.sh username@server

# With custom port and SSH key
./audit.sh -p 2222 -i ~/.ssh/id_ed25519 root@203.0.113.10

##📂 Example Output
	•	facts_<host>.json – full Ansible facts
	•	packages_<host>.json – structured list of installed packages
	•	services_<host>.json – registered services
	•	services_running_<host>.txt – running services snapshot
	•	listening_ports_<host>.txt – open ports and listeners
	•	lsblk_<host>.txt, df_<host>.txt – disk/FS overview
	•	top_cpu_<host>.txt, top_mem_<host>.txt – top processes
	•	configs/ – selected configuration files from /etc

##⚠️ Notes
	•	Ensure your control node has LANG/LC_ALL set to UTF-8 (e.g. export LANG=C.UTF-8).
	•	This script is read-only and does not make changes to the target server.
	•	You can extend the list of configuration files in the playbook section cfg_candidates.
