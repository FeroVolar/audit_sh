#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-p PORT] [-i SSH_KEY] username@server

Examples:
  $(basename "$0") root@203.0.113.10
  $(basename "$0") -p 2222 -i ~/.ssh/id_ed25519 admin@my.server.com
EOF
}

PORT=""
SSH_KEY=""
while getopts ":p:i:h" opt; do
  case $opt in
    p) PORT="$OPTARG" ;;
    i) SSH_KEY="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Option -$OPTARG requires a value." >&2; usage; exit 1 ;;
  esac
done
shift $((OPTIND-1))

if [[ $# -lt 1 ]]; then
  usage; exit 1
fi

TARGET="$1"
HOST="${TARGET#*@}"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="server-audit_${HOST}_${TS}"
mkdir -p "$OUTDIR"

# --- Dependency check ---
if ! command -v ansible >/dev/null 2>&1; then
  echo "'ansible' is missing. Install it (e.g. 'pipx install ansible' or via your package manager) and run the script again."
  exit 1
fi

# --- Temporary inventory ---
INVENTORY="$OUTDIR/inventory.ini"
{
  echo "[targets]"
  echo "$HOST ansible_user=${TARGET%@*}"
  [[ -n "$PORT" ]] && echo "$HOST ansible_port=$PORT"
  [[ -n "$SSH_KEY" ]] && echo "$HOST ansible_ssh_private_key_file=$SSH_KEY"
} > "$INVENTORY"

# --- Playbook (everything in one file) ---
PLAYBOOK="$OUTDIR/audit.yml"
cat > "$PLAYBOOK" <<'YAML'
---
- name: Lightweight server audit
  hosts: targets
  gather_facts: true
  vars:
    audit_dir: "{{ lookup('env', 'AUDIT_DIR') | default('./audit-out', true) }}"
  pre_tasks:
    - name: Create local directory for the report (on control node)
      ansible.builtin.file:
        path: "{{ audit_dir }}"
        state: directory
        mode: "0755"
      delegate_to: localhost
      run_once: true

  tasks:
    # --- Facts (hardware/OS/network/mounts etc.) ---
    - name: Save ansible_facts to JSON (locally)
      ansible.builtin.copy:
        content: "{{ ansible_facts | to_nice_json }}"
        dest: "{{ audit_dir }}/facts_{{ inventory_hostname }}.json"
        mode: "0644"
      delegate_to: localhost

    # --- Packages ---
    - name: Gather packages (package_facts)
      ansible.builtin.package_facts:
        manager: auto

    - name: Save packages to JSON (locally)
      ansible.builtin.copy:
        content: "{{ ansible_facts.packages | default({}) | to_nice_json }}"
        dest: "{{ audit_dir }}/packages_{{ inventory_hostname }}.json"
        mode: "0644"
      delegate_to: localhost

    # Raw list by OS type
    - name: List packages (Debian/Ubuntu)
      ansible.builtin.command: dpkg -l
      register: deb_packages
      changed_when: false
      failed_when: false
      when: ansible_facts.os_family == 'Debian'

    - name: Save dpkg -l (locally)
      ansible.builtin.copy:
        content: "{{ deb_packages.stdout | default('') }}"
        dest: "{{ audit_dir }}/packages_dpkg_{{ inventory_hostname }}.txt"
        mode: "0644"
      when: deb_packages is defined
      delegate_to: localhost

    - name: List packages (RHEL/CentOS/Fedora)
      ansible.builtin.command: rpm -qa
      register: rpm_packages
      changed_when: false
      failed_when: false
      when: ansible_facts.os_family == 'RedHat'

    - name: Save rpm -qa (locally)
      ansible.builtin.copy:
        content: "{{ rpm_packages.stdout | default('') }}"
        dest: "{{ audit_dir }}/packages_rpm_{{ inventory_hostname }}.txt"
        mode: "0644"
      when: rpm_packages is defined
      delegate_to: localhost

    # --- Services ---
    - name: Gather service facts
      ansible.builtin.service_facts:

    - name: Save services to JSON (locally)
      ansible.builtin.copy:
        content: "{{ ansible_facts.services | default({}) | to_nice_json }}"
        dest: "{{ audit_dir }}/services_{{ inventory_hostname }}.json"
        mode: "0644"
      delegate_to: localhost

    - name: Running systemd services (raw)
      ansible.builtin.command: systemctl list-units --type=service --state=running
      register: running_services
      changed_when: false
      failed_when: false

    - name: Save running services (locally)
      ansible.builtin.copy:
        content: "{{ running_services.stdout | default('') }}"
        dest: "{{ audit_dir }}/services_running_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    # --- Network and ports ---
    - name: Open ports (ss)
      ansible.builtin.command: ss -tulpn
      register: ss_out
      changed_when: false
      failed_when: false

    - name: Save ss -tulpn (locally)
      ansible.builtin.copy:
        content: "{{ ss_out.stdout | default('') }}"
        dest: "{{ audit_dir }}/listening_ports_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    # --- Disks and FS ---
    - name: Disks and partitions (lsblk)
      ansible.builtin.command: lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,TYPE
      register: lsblk_out
      changed_when: false
      failed_when: false

    - name: Save lsblk (locally)
      ansible.builtin.copy:
        content: "{{ lsblk_out.stdout | default('') }}"
        dest: "{{ audit_dir }}/lsblk_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    - name: DF -h
      ansible.builtin.command: df -h
      register: df_out
      changed_when: false
      failed_when: false

    - name: Save df -h (locally)
      ansible.builtin.copy:
        content: "{{ df_out.stdout | default('') }}"
        dest: "{{ audit_dir }}/df_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    # --- Processes ---
    - name: Top processes by CPU
      ansible.builtin.shell: ps aux --sort=-%cpu | head -n 50
      args: { executable: /bin/bash }
      register: ps_cpu
      changed_when: false
      failed_when: false

    - name: Save top CPU processes (locally)
      ansible.builtin.copy:
        content: "{{ ps_cpu.stdout | default('') }}"
        dest: "{{ audit_dir }}/top_cpu_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    - name: Top processes by RSS
      ansible.builtin.shell: ps aux --sort=-rss | head -n 50
      args: { executable: /bin/bash }
      register: ps_mem
      changed_when: false
      failed_when: false

    - name: Save top MEM processes (locally)
      ansible.builtin.copy:
        content: "{{ ps_mem.stdout | default('') }}"
        dest: "{{ audit_dir }}/top_mem_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    # --- Config files (if they exist) ---
    - name: Candidate config files to fetch
      ansible.builtin.set_fact:
        cfg_candidates:
          - /etc/ssh/sshd_config
          - /etc/nginx/nginx.conf
          - /etc/nginx/sites-enabled/default
          - /etc/apache2/apache2.conf
          - /etc/httpd/conf/httpd.conf
          - /etc/fstab
          - /etc/hosts
          - /etc/resolv.conf

    - name: Check existing configs
      ansible.builtin.stat:
        path: "{{ item }}"
      loop: "{{ cfg_candidates }}"
      register: cfg_stats

    - name: Fetch existing configs (locally)
      ansible.builtin.fetch:
        src: "{{ item.stat.path }}"
        dest: "{{ audit_dir }}/configs/"
        flat: yes
      loop: "{{ cfg_stats.results | selectattr('stat.exists') | list }}"
      loop_control:
        label: "{{ item.stat.path }}"

  post_tasks:
    - name: Summary info about output
      ansible.builtin.debug:
        msg: "Reports for {{ inventory_hostname }} saved to {{ audit_dir }}"
YAML

# --- Run the playbook ---
export ANSIBLE_HOST_KEY_CHECKING=False
export AUDIT_DIR="$(cd "$OUTDIR" && mkdir -p report && cd - >/dev/null; echo "$OUTDIR/report")"

SSH_EXTRA=""
[[ -n "$PORT" ]] && SSH_EXTRA="$SSH_EXTRA -p $PORT"
[[ -n "$SSH_KEY" ]] && SSH_EXTRA="$SSH_EXTRA -i $SSH_KEY"
SSH_EXTRA="$SSH_EXTRA -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ansible-playbook -i "$INVENTORY" "$PLAYBOOK" \
  --ssh-extra-args "$SSH_EXTRA"

echo
echo "✅ Done. Reports are in: $AUDIT_DIR"
find "$AUDIT_DIR" -maxdepth 2 -type f -print | sed 's/^/- /'