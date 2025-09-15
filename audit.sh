#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Použitie: $(basename "$0") [-p PORT] [-i SSH_KEY] username@server

Príklady:
  $(basename "$0") root@203.0.113.10
  $(basename "$0") -p 2222 -i ~/.ssh/id_ed25519 admin@moj.server.com
EOF
}

PORT=""
SSH_KEY=""
while getopts ":p:i:h" opt; do
  case $opt in
    p) PORT="$OPTARG" ;;
    i) SSH_KEY="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Neznámy prepínač -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Prepínač -$OPTARG vyžaduje hodnotu." >&2; usage; exit 1 ;;
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

# --- Kontrola závislostí ---
if ! command -v ansible >/dev/null 2>&1; then
  echo "Chýba 'ansible'. Nainštaluj ho (napr. 'pipx install ansible' alebo balíčkovací manažér) a spusti skript znova."
  exit 1
fi

# --- Dočasný inventory ---
INVENTORY="$OUTDIR/inventory.ini"
{
  echo "[targets]"
  echo "$HOST ansible_user=${TARGET%@*}"
  [[ -n "$PORT" ]] && echo "$HOST ansible_port=$PORT"
  [[ -n "$SSH_KEY" ]] && echo "$HOST ansible_ssh_private_key_file=$SSH_KEY"
} > "$INVENTORY"

# --- Playbook (1 súbor, všetko spolu) ---
PLAYBOOK="$OUTDIR/audit.yml"
cat > "$PLAYBOOK" <<'YAML'
---
- name: Lightweight server audit
  hosts: targets
  gather_facts: true
  vars:
    audit_dir: "{{ lookup('env', 'AUDIT_DIR') | default('./audit-out', true) }}"
  pre_tasks:
    - name: Vytvor lokálny priečinok pre report (na control node)
      ansible.builtin.file:
        path: "{{ audit_dir }}"
        state: directory
        mode: "0755"
      delegate_to: localhost
      run_once: true

  tasks:
    # --- Fakty (hardware/OS/sieť/mounty atď.) ---
    - name: Ulož ansible_facts do JSON (lokálne)
      ansible.builtin.copy:
        content: "{{ ansible_facts | to_nice_json }}"
        dest: "{{ audit_dir }}/facts_{{ inventory_hostname }}.json"
        mode: "0644"
      delegate_to: localhost

    # --- Balíčky ---
    - name: Nazbieraj balíčky (package_facts)
    # funguje pre apt/yum/dnf/zypper/… podľa OS
      ansible.builtin.package_facts:
        manager: auto

    - name: Ulož balíčky do JSON (lokálne)
      ansible.builtin.copy:
        content: "{{ ansible_facts.packages | default({}) | to_nice_json }}"
        dest: "{{ audit_dir }}/packages_{{ inventory_hostname }}.json"
        mode: "0644"
      delegate_to: localhost

    # Pre istotu aj surový výpis podľa OS
    - name: Zoznam balíkov (Debian/Ubuntu)
      ansible.builtin.command: dpkg -l
      register: deb_packages
      changed_when: false
      failed_when: false
      when: ansible_facts.os_family == 'Debian'

    - name: Zapíš dpkg -l (lokálne)
      ansible.builtin.copy:
        content: "{{ deb_packages.stdout | default('') }}"
        dest: "{{ audit_dir }}/packages_dpkg_{{ inventory_hostname }}.txt"
        mode: "0644"
      when: deb_packages is defined
      delegate_to: localhost

    - name: Zoznam balíkov (RHEL/CentOS/Fedora)
      ansible.builtin.command: rpm -qa
      register: rpm_packages
      changed_when: false
      failed_when: false
      when: ansible_facts.os_family == 'RedHat'

    - name: Zapíš rpm -qa (lokálne)
      ansible.builtin.copy:
        content: "{{ rpm_packages.stdout | default('') }}"
        dest: "{{ audit_dir }}/packages_rpm_{{ inventory_hostname }}.txt"
        mode: "0644"
      when: rpm_packages is defined
      delegate_to: localhost

    # --- Služby ---
    - name: Nazbieraj service facts
      ansible.builtin.service_facts:

    - name: Ulož služby do JSON (lokálne)
      ansible.builtin.copy:
        content: "{{ ansible_facts.services | default({}) | to_nice_json }}"
        dest: "{{ audit_dir }}/services_{{ inventory_hostname }}.json"
        mode: "0644"
      delegate_to: localhost

    - name: Bežiace systemd služby (raw)
      ansible.builtin.command: systemctl list-units --type=service --state=running
      register: running_services
      changed_when: false
      failed_when: false

    - name: Zapíš bežiace služby (lokálne)
      ansible.builtin.copy:
        content: "{{ running_services.stdout | default('') }}"
        dest: "{{ audit_dir }}/services_running_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    # --- Sieť a porty ---
    - name: Otvorené porty (ss)
      ansible.builtin.command: ss -tulpn
      register: ss_out
      changed_when: false
      failed_when: false

    - name: Zapíš ss -tulpn (lokálne)
      ansible.builtin.copy:
        content: "{{ ss_out.stdout | default('') }}"
        dest: "{{ audit_dir }}/listening_ports_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    # --- Disky a FS ---
    - name: Disky a partície (lsblk)
      ansible.builtin.command: lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,TYPE
      register: lsblk_out
      changed_when: false
      failed_when: false

    - name: Zapíš lsblk (lokálne)
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

    - name: Zapíš df -h (lokálne)
      ansible.builtin.copy:
        content: "{{ df_out.stdout | default('') }}"
        dest: "{{ audit_dir }}/df_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    # --- Procesy ---
    - name: Top procesy podľa CPU
      ansible.builtin.shell: ps aux --sort=-%cpu | head -n 50
      args: { executable: /bin/bash }
      register: ps_cpu
      changed_when: false
      failed_when: false

    - name: Zapíš top CPU procesy (lokálne)
      ansible.builtin.copy:
        content: "{{ ps_cpu.stdout | default('') }}"
        dest: "{{ audit_dir }}/top_cpu_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    - name: Top procesy podľa RSS
      ansible.builtin.shell: ps aux --sort=-rss | head -n 50
      args: { executable: /bin/bash }
      register: ps_mem
      changed_when: false
      failed_when: false

    - name: Zapíš top MEM procesy (lokálne)
      ansible.builtin.copy:
        content: "{{ ps_mem.stdout | default('') }}"
        dest: "{{ audit_dir }}/top_mem_{{ inventory_hostname }}.txt"
        mode: "0644"
      delegate_to: localhost

    # --- Konfiguračné súbory (ak existujú) ---
    - name: Zoznam sledovaných config súborov
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

    - name: Filtrovanie existujúcich configov
      ansible.builtin.stat:
        path: "{{ item }}"
      loop: "{{ cfg_candidates }}"
      register: cfg_stats

    - name: Stiahni existujúce configy (lokálne)
      ansible.builtin.fetch:
        src: "{{ item.stat.path }}"
        dest: "{{ audit_dir }}/configs/"
        flat: yes
      loop: "{{ cfg_stats.results | selectattr('stat.exists') | list }}"
      loop_control:
        label: "{{ item.stat.path }}"

  post_tasks:
    - name: Stručné info o výstupe
      ansible.builtin.debug:
        msg: "Reporty pre {{ inventory_hostname }} uložené do {{ audit_dir }}"
YAML

# --- Spustenie playbooku ---
export ANSIBLE_HOST_KEY_CHECKING=False
export AUDIT_DIR="$(cd "$OUTDIR" && mkdir -p report && cd - >/dev/null; echo "$OUTDIR/report")"

SSH_EXTRA=""
[[ -n "$PORT" ]] && SSH_EXTRA="$SSH_EXTRA -p $PORT"
[[ -n "$SSH_KEY" ]] && SSH_EXTRA="$SSH_EXTRA -i $SSH_KEY"
# Odporúčané: vypnúť interaktívne otázky o host key
SSH_EXTRA="$SSH_EXTRA -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ansible-playbook -i "$INVENTORY" "$PLAYBOOK" \
  --ssh-extra-args "$SSH_EXTRA"

echo
echo "✅ Hotovo. Výstupy sú v: $AUDIT_DIR"
find "$AUDIT_DIR" -maxdepth 2 -type f -print | sed 's/^/- /'