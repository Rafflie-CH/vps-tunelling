#!/bin/bash
# ================================================================
# LOAD BALANCER PINTAR - Auto Redirect Semua Proses ke Worker
# Tanpa ubah kode, support PM2, auto install dependensi worker
# ================================================================

set -e
trap 'echo -e "\n❌ Error fatal. Script berhenti."; exit 1' ERR

# Warna
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}     LOAD BALANCER PINTAR - Auto Redirect ke Worker         ${NC}"
echo -e "${GREEN}============================================================${NC}"

# --- Konfigurasi ---
WORKER_FILE="/etc/loadbalancer/workers"
INDEX_FILE="/tmp/run_roundrobin_index"
WRAPPER_FILE="/usr/local/bin/run-wrapper"

mkdir -p /etc/loadbalancer
touch "$WORKER_FILE"

# --- Fungsi untuk prompt dengan back & exit ---
prompt_with_back_exit() {
    local prompt_msg="$1"
    local default_val="$2"
    local input
    while true; do
        if [ -n "$default_val" ]; then
            read -p "$prompt_msg (default: $default_val): " input
            [ -z "$input" ] && input="$default_val"
        else
            read -p "$prompt_msg: " input
        fi
        case "$input" in
            exit) echo -e "${RED}Dibatalkan.${NC}"; exit 0 ;;
            back) return 1 ;;
            *) echo "$input"; return 0 ;;
        esac
    done
}

prompt_password() {
    local input
    while true; do
        read -s -p "Password root: " input
        echo
        [ -z "$input" ] && echo -e "${RED}Password tidak boleh kosong.${NC}" && continue
        case "$input" in
            exit) echo -e "${RED}Dibatalkan.${NC}"; exit 0 ;;
            back) return 1 ;;
            *) echo "$input"; return 0 ;;
        esac
    done
}

# --- Fungsi tambah worker ---
add_worker() {
    local ip="$1" port="$2" pass="$3"
    local max_retry=2 attempt=0
    while [ $attempt -lt $max_retry ]; do
        if sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" root@"$ip" 2>/dev/null; then
            echo "$ip:$port" >> "$WORKER_FILE"
            echo -e "${GREEN}  ✓ Worker $ip:$port berhasil${NC}"
            return 0
        fi
        attempt=$((attempt+1))
        sleep 1
    done
    echo -e "${RED}  ✗ Worker $ip:$port gagal${NC}"
    return 1
}

# --- Fungsi install dependensi di worker ---
install_deps_worker() {
    local ip="$1" port="$2"
    echo -e "${BLUE}  ➔ Install dependensi di $ip:$port...${NC}"
    ssh -p "$port" -o StrictHostKeyChecking=no root@"$ip" '
        apt-get update -qq
        apt-get install -y -qq python3 python3-pip nodejs npm ffmpeg imagemagick curl wget git
        # Tambahkan yang lain sesuai kebutuhan
        echo "Dependencies installed"
    ' 2>/dev/null && echo -e "${GREEN}  ✓ Dependencies installed di $ip${NC}" || echo -e "${RED}  ✗ Gagal install di $ip${NC}"
}

# --- 1. Install sshpass di utama ---
echo -e "${GREEN}[1/7] Install sshpass...${NC}"
if ! command -v sshpass &> /dev/null; then
    apt-get update -qq && apt-get install sshpass -y -qq
fi

# --- 2. Generate SSH key ---
echo -e "${GREEN}[2/7] Pastikan SSH key tersedia...${NC}"
[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""

# --- 3. Cek worker yang sudah ada ---
EXISTING_WORKERS=()
if [ -s "$WORKER_FILE" ]; then
    mapfile -t EXISTING_WORKERS < "$WORKER_FILE"
    echo -e "${GREEN}✅ Ditemukan ${#EXISTING_WORKERS[@]} worker terdaftar:${NC}"
    for w in "${EXISTING_WORKERS[@]}"; do
        echo "  - $w"
    done
fi

# --- 4. Tentukan aksi ---
if [ ${#EXISTING_WORKERS[@]} -eq 0 ]; then
    echo -e "${YELLOW}Belum ada worker. Silakan tambahkan.${NC}"
    ACTION="add"
else
    echo -e "${YELLOW}Ingin menambah worker baru? (y/n)${NC}"
    read -r ADD_NEW
    if [[ "$ADD_NEW" =~ ^[Yy]$ ]]; then
        ACTION="add"
    else
        ACTION="restart"
    fi
fi

# --- 5. Proses tambah worker jika diperlukan ---
if [ "$ACTION" = "add" ]; then
    echo -e "${GREEN}[3/7] Tambah Worker Baru${NC}"
    echo -n "Jumlah worker yang akan ditambahkan: "
    read -r NEW_COUNT
    if ! [[ "$NEW_COUNT" =~ ^[0-9]+$ ]] || [ "$NEW_COUNT" -eq 0 ]; then
        echo -e "${RED}Jumlah harus angka positif.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Pilih mode input:${NC}"
    echo "  1) Single (input satu per satu)"
    echo "  2) Batch (paste semua baris: IP PORT PASSWORD)"
    read -p "Pilihan (1/2): " MODE
    if [[ ! "$MODE" =~ ^[12]$ ]]; then
        echo -e "${RED}Pilihan tidak valid.${NC}"
        exit 1
    fi

    declare -a NEW_WORKERS
    if [ "$MODE" = "1" ]; then
        for ((i=1; i<=NEW_COUNT; i++)); do
            echo -e "${YELLOW}--- Worker ke-$i ---${NC}"
            while true; do
                IP=$(prompt_with_back_exit "IP address" "")
                [ $? -eq 1 ] && continue
                PORT=$(prompt_with_back_exit "Port SSH" "22")
                [ $? -eq 1 ] && continue
                PASS=$(prompt_password)
                [ $? -eq 1 ] && continue
                NEW_WORKERS+=("$IP:$PORT:$PASS")
                break
            done
        done
    else
        echo -e "${YELLOW}Paste daftar (format: IP PORT PASSWORD), ENTER kosong untuk selesai.${NC}"
        echo "Contoh: 192.168.1.100 22 mypass123"
        read -p "Tekan Enter..."
        count=0
        while [ $count -lt $NEW_COUNT ]; do
            read -r line
            [ -z "$line" ] && break
            set -- $line
            if [ $# -lt 3 ]; then
                echo -e "${RED}Format salah, lewati.${NC}"
                continue
            fi
            ip="$1"; port="$2"; shift 2; pass="$*"
            NEW_WORKERS+=("$ip:$port:$pass")
            count=$((count+1))
            echo -e "${BLUE}  ➔ Ditambahkan: $ip:$port${NC}"
        done
        if [ $count -lt $NEW_COUNT ]; then
            echo -e "${YELLOW}Hanya $count dari $NEW_COUNT worker dimasukkan. Lanjut? (y/n)${NC}"
            read -r confirm
            [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
        fi
    fi

    # Konfirmasi
    echo -e "${GREEN}Daftar worker baru:${NC}"
    for w in "${NEW_WORKERS[@]}"; do
        IFS=':' read -r ip port pass <<< "$w"
        echo "  - $ip:$port"
    done
    echo -e "${YELLOW}Lanjutkan setup? (y/n)${NC}"
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0

    # Proses add worker
    echo -e "${GREEN}[4/7] Menyalin SSH key ke worker...${NC}"
    for w in "${NEW_WORKERS[@]}"; do
        IFS=':' read -r ip port pass <<< "$w"
        echo -e "${BLUE}  ➔ $ip:$port${NC}"
        if add_worker "$ip" "$port" "$pass"; then
            # Install dependensi di worker
            install_deps_worker "$ip" "$port" &
        fi
    done
    wait
    echo -e "${GREEN}✅ Semua worker baru selesai diproses.${NC}"
fi

# --- 6. Buat wrapper untuk redirect semua perintah ke worker ---
echo -e "${GREEN}[5/7] Membuat wrapper...${NC}"
cat > "$WRAPPER_FILE" <<'EOF'
#!/bin/bash
# Wrapper untuk redirect SEMUA perintah (kecuali dasar) ke worker

LOCAL_CMDS="^(pm2|node|npm|yarn|cd|ls|pwd|echo|cat|grep|sed|awk|kill|ps|top|htop|free|df|du|whoami|id|sleep|wait|exit|export|unset|set|source|alias|unalias|type|which|find|xargs|wc|sort|uniq|head|tail|cut|tr|tee|date|cal|clear|history|fg|bg|jobs|ulimit|umask)$"

if [[ "$1" =~ $LOCAL_CMDS ]]; then
    exec "$@"
else
    /usr/local/bin/run "$@"
fi
EOF
chmod +x "$WRAPPER_FILE"

# --- 7. Buat script `run` jika belum ada ---
if [ ! -f /usr/local/bin/run ]; then
    echo -e "${GREEN}[6/7] Membuat perintah 'run'...${NC}"
    cat > /usr/local/bin/run <<'EOF'
#!/bin/bash
WORKER_FILE="/etc/loadbalancer/workers"
INDEX_FILE="/tmp/run_roundrobin_index"

[ ! -f "$WORKER_FILE" ] || [ ! -s "$WORKER_FILE" ] && echo "ERROR: No workers." && exit 1
[ $# -eq 0 ] && echo "Usage: run \"command\"" && exit 1

mapfile -t WORKERS < "$WORKER_FILE"
TOTAL=${#WORKERS[@]}
[ -f "$INDEX_FILE" ] && LAST=$(cat "$INDEX_FILE") || LAST=-1
NEXT=$(( (LAST + 1) % TOTAL ))
echo "$NEXT" > "$INDEX_FILE"

for ((attempt=0; attempt<TOTAL; attempt++)); do
    WORKER="${WORKERS[$NEXT]}"
    IP=$(echo "$WORKER" | cut -d':' -f1)
    PORT=$(echo "$WORKER" | cut -d':' -f2)
    if ssh -p "$PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" "$@" 2>/dev/null; then
        exit 0
    fi
    NEXT=$(( (NEXT + 1) % TOTAL ))
done
echo "ERROR: All workers down." >&2
exit 1
EOF
    chmod +x /usr/local/bin/run
fi

# --- 8. Buat script `vt` jika belum ada ---
if [ ! -f /usr/local/bin/vt ]; then
    echo -e "${GREEN}[7/7] Membuat perintah 'vt'...${NC}"
    cat > /usr/local/bin/vt <<'EOF'
#!/bin/bash
# vt - Manajemen Worker

WORKER_FILE="/etc/loadbalancer/workers"
INDEX_FILE="/tmp/run_roundrobin_index"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

show_help() {
    cat <<HELP
${GREEN}vt - Manajemen Worker Load Balancer${NC}
  ${BLUE}list${NC}       - Tampilkan worker + status
  ${BLUE}add${NC}        - Tambah worker (mode single/batch)
  ${BLUE}disconnect ID${NC} - Hapus worker
  ${BLUE}restart${NC}   - Restart PM2 dengan wrapper (redirect semua proses)
  ${BLUE}help${NC}       - Bantuan
HELP
}

cmd_list() {
    [ ! -s "$WORKER_FILE" ] && echo -e "${RED}Tidak ada worker.${NC}" && return 1
    mapfile -t WORKERS < "$WORKER_FILE"
    echo -e "${GREEN}=== Daftar Worker ===${NC}"
    printf "%-4s %-20s %-6s %-10s %-15s %-20s %s\n" "ID" "IP" "Port" "Status" "RAM" "Uptime" "Load"
    local id=1
    for w in "${WORKERS[@]}"; do
        ip=$(echo "$w" | cut -d':' -f1); port=$(echo "$w" | cut -d':' -f2)
        info=$(ssh -p "$port" -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@"$ip" '
            echo "OK"
            free -h | grep -i mem | awk "{print \$2,\$3,\$4}"
            uptime -p | sed "s/up //"
            cat /proc/loadavg | awk "{print \$1,\$2,\$3}"
        ' 2>/dev/null)
        if [ $? -eq 0 ]; then
            IFS=$'\n' read -r status mem uptime load <<< "$info"
            status="${GREEN}ONLINE${NC}"
        else
            status="${RED}OFFLINE${NC}"; mem="-"; uptime="-"; load="-"
        fi
        printf "%-4s %-20s %-6s %-10b %-15s %-20s %s\n" "$id" "$ip" "$port" "$status" "$mem" "$uptime" "$load"
        ((id++))
    done
}

cmd_add() {
    echo -e "${YELLOW}Tambah Worker Baru${NC}"
    echo -n "Mode (1=single, 2=batch): "
    read -r mode
    if [ "$mode" = "1" ]; then
        echo -n "IP: "; read -r ip
        echo -n "Port (default 22): "; read -r port; [ -z "$port" ] && port=22
        echo -n "Password: "; read -rs pass; echo
        if sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -p "$port" root@"$ip"; then
            echo "$ip:$port" >> "$WORKER_FILE"
            echo -e "${GREEN}Worker added.${NC}"
        else
            echo -e "${RED}Gagal.${NC}"
        fi
    elif [ "$mode" = "2" ]; then
        echo "Paste list (IP PORT PASSWORD), ENTER kosong selesai:"
        while read -r line; do
            [ -z "$line" ] && break
            set -- $line
            [ $# -lt 3 ] && echo "Format salah, lewati." && continue
            ip="$1"; port="$2"; shift 2; pass="$*"
            if sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -p "$port" root@"$ip"; then
                echo "$ip:$port" >> "$WORKER_FILE"
                echo -e "${GREEN}Added $ip:$port${NC}"
            else
                echo -e "${RED}Failed $ip:$port${NC}"
            fi
        done
    else
        echo -e "${RED}Mode salah.${NC}"
    fi
}

cmd_disconnect() {
    local id="$1"
    [ -z "$id" ] && echo "Usage: vt disconnect ID" && return 1
    mapfile -t WORKERS < "$WORKER_FILE"
    if [ "$id" -gt "${#WORKERS[@]}" ] || [ "$id" -lt 1 ]; then
        echo -e "${RED}ID tidak ditemukan.${NC}"; return 1
    fi
    local new=()
    local i=1
    for w in "${WORKERS[@]}"; do
        [ "$i" -ne "$id" ] && new+=("$w")
        ((i++))
    done
    printf "%s\n" "${new[@]}" > "$WORKER_FILE"
    rm -f "$INDEX_FILE"
    echo -e "${GREEN}Worker $id dihapus.${NC}"
}

cmd_restart() {
    echo -e "${YELLOW}Restart PM2 dengan wrapper...${NC}"
    # Set environment SHELL di .bashrc
    if ! grep -q "export SHELL=/usr/local/bin/run-wrapper" ~/.bashrc; then
        echo 'export SHELL=/usr/local/bin/run-wrapper' >> ~/.bashrc
    fi
    export SHELL=/usr/local/bin/run-wrapper
    # Restart semua proses PM2
    if command -v pm2 &> /dev/null; then
        pm2 restart all --update-env 2>/dev/null || pm2 restart all
        echo -e "${GREEN}✅ PM2 restart selesai. Semua proses sekarang pakai wrapper.${NC}"
        echo -e "${YELLOW}Catatan: Perintah berat akan otomatis ke worker.${NC}"
    else
        echo -e "${RED}PM2 tidak terinstall.${NC}"
    fi
}

case "$1" in
    list) cmd_list ;;
    add) cmd_add ;;
    disconnect) cmd_disconnect "$2" ;;
    restart) cmd_restart ;;
    help|--help|-h|"") show_help ;;
    *) echo -e "${RED}Perintah tidak dikenal.${NC}"; show_help ;;
esac
EOF
    chmod +x /usr/local/bin/vt
fi

# --- 9. Restart PM2 jika diminta ---
if [ "$ACTION" = "restart" ] || [ ${#EXISTING_WORKERS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Apakah Anda ingin merestart semua proses PM2 dengan wrapper? (y/n)${NC}"
    read -r RESTART_PM2
    if [[ "$RESTART_PM2" =~ ^[Yy]$ ]]; then
        vt restart
    else
        echo -e "${YELLOW}Anda bisa menjalankan 'vt restart' nanti.${NC}"
    fi
else
    echo -e "${YELLOW}Apakah ingin langsung restart PM2 sekarang? (y/n)${NC}"
    read -r RESTART_PM2
    if [[ "$RESTART_PM2" =~ ^[Yy]$ ]]; then
        vt restart
    fi
fi

# --- 10. Selesai ---
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}✅ SEMUA SELESAI!${NC}"
echo -e "Perintah tersedia:"
echo -e "  ${BLUE}run \"perintah\"${NC}    - jalankan perintah di worker"
echo -e "  ${BLUE}vt list${NC}           - lihat worker + status"
echo -e "  ${BLUE}vt add${NC}            - tambah worker (mode single/batch)"
echo -e "  ${BLUE}vt disconnect ID${NC}  - hapus worker"
echo -e "  ${BLUE}vt restart${NC}        - restart PM2 dengan wrapper"
echo -e "Worker terdaftar:"
[ -s "$WORKER_FILE" ] && cat "$WORKER_FILE" | while read -r line; do echo "  - $line"; done || echo "  (tidak ada)"
echo -e "${GREEN}============================================================${NC}"
echo -e "${YELLOW}Catatan:${NC}"
echo "  • Semua perintah berat dari bot akan otomatis dijalankan di worker."
echo "  • Untuk mengaktifkan perubahan di shell saat ini, jalankan: source ~/.bashrc"
echo "  • Jika ada worker baru, jalankan 'vt add' lalu 'vt restart' untuk aktifkan."
