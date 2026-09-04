#!/bin/bash
# =========================================================
# Load Balancer Proses - Eksekusi Perintah ke Worker
# Tanpa login pihak ketiga, hanya SSH + key
# Support batch input & tanpa sudo/systemd
# =========================================================

set -e
trap 'echo -e "\n❌ Error fatal. Script berhenti."; exit 1' ERR

# Warna
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}  Load Balancer Perintah (Round-Robin via SSH) SUPPORT MULTI  ${NC}"
echo -e "${GREEN}==============================================================${NC}"

# --- Fungsi untuk prompt dengan back & exit (single mode) ---
prompt_with_back_exit() {
    local prompt_msg="$1"
    local default_val="$2"
    local input
    while true; do
        if [ -n "$default_val" ]; then
            read -p "$prompt_msg (default: $default_val): " input
            if [ -z "$input" ]; then input="$default_val"; fi
        else
            read -p "$prompt_msg: " input
        fi
        case "$input" in
            exit)
                echo -e "${RED}Instalasi dibatalkan.${NC}"
                exit 0
                ;;
            back)
                return 1
                ;;
            *)
                echo "$input"
                return 0
                ;;
        esac
    done
}

prompt_password() {
    local prompt_msg="$1"
    local input
    while true; do
        read -s -p "$prompt_msg: " input
        echo
        if [ -z "$input" ]; then
            echo -e "${RED}Password tidak boleh kosong.${NC}"
            continue
        fi
        case "$input" in
            exit)
                echo -e "${RED}Instalasi dibatalkan.${NC}"
                exit 0
                ;;
            back)
                return 1
                ;;
            *)
                echo "$input"
                return 0
                ;;
        esac
    done
}

# --- Fungsi untuk menambahkan worker (dengan retry jika gagal) ---
add_worker() {
    local ip="$1"
    local port="$2"
    local pass="$3"
    local max_retry=2
    local attempt=0
    while [ $attempt -lt $max_retry ]; do
        if sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" root@"$ip" 2>/dev/null; then
            echo "$ip:$port" >> "$WORKER_FILE"
            echo -e "${GREEN}  ✓ Worker $ip:$port berhasil${NC}"
            return 0
        fi
        attempt=$((attempt+1))
        sleep 1
    done
    echo -e "${RED}  ✗ Worker $ip:$port gagal (password salah atau koneksi)${NC}"
    return 1
}

# --- 1. Install sshpass (tanpa sudo) ---
echo -e "${GREEN}[1/6] Install sshpass...${NC}"
if ! command -v sshpass &> /dev/null; then
    apt-get update -qq && apt-get install sshpass -y -qq
fi

# --- 2. Generate SSH key ---
echo -e "${GREEN}[2/6] Pastikan SSH key tersedia...${NC}"
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""
fi

# --- 3. Minta jumlah worker ---
echo -e "${YELLOW}Masukkan jumlah VPS worker:${NC}"
WORKER_COUNT=$(prompt_with_back_exit "Jumlah worker" "")
if ! [[ "$WORKER_COUNT" =~ ^[0-9]+$ ]] || [ "$WORKER_COUNT" -eq 0 ]; then
    echo -e "${RED}Jumlah worker harus angka positif!${NC}"
    exit 1
fi

# --- 4. Pilih mode input ---
echo -e "${YELLOW}Pilih mode input:${NC}"
echo "  1) Single (input satu per satu dengan back/exit)"
echo "  2) Batch (paste semua baris: IP PORT PASSWORD)"
read -p "Pilihan (1/2): " MODE
if [[ ! "$MODE" =~ ^[12]$ ]]; then
    echo -e "${RED}Pilihan tidak valid. Gunakan 1 atau 2.${NC}"
    exit 1
fi

# Buat direktori konfigurasi
mkdir -p /etc/loadbalancer
WORKER_FILE="/etc/loadbalancer/workers"
> "$WORKER_FILE"

declare -a WORKER_LIST
declare -a FAILED_WORKERS

# --- 5. Kumpulkan data worker sesuai mode ---
if [ "$MODE" = "1" ]; then
    echo -e "${GREEN}[3/6] Setup akses ke worker (single mode)...${NC}"
    for ((i=1; i<=WORKER_COUNT; i++)); do
        echo -e "${YELLOW}--- Worker ke-$i (ketik 'back' untuk ulangi, 'exit' untuk batal) ---${NC}"
        while true; do
            IP=$(prompt_with_back_exit "IP address worker" "")
            if [ $? -eq 1 ]; then continue; fi
            PORT=$(prompt_with_back_exit "Port SSH worker" "22")
            if [ $? -eq 1 ]; then continue; fi
            echo -n "Password root worker: "
            PASS=$(prompt_password "Password")
            if [ $? -eq 1 ]; then continue; fi
            WORKER_LIST+=("$IP:$PORT:$PASS")
            break
        done
    done
else
    echo -e "${GREEN}[3/6] Setup akses ke worker (batch mode)...${NC}"
    echo -e "${YELLOW}Paste daftar worker (format: IP PORT PASSWORD), satu baris per worker."
    echo -e "Ketik ${BLUE}DONE${YELLOW} pada baris kosong setelah selesai.${NC}"
    echo "Contoh:"
    echo "  66.33.xx.xxx 42xx xxxxxx"
    echo "  66.xx.22.2xx xx55 xxxxxx"
    echo
    read -p "Tekan Enter untuk mulai memasukkan data..."

    local count=0
    while [ $count -lt $WORKER_COUNT ]; do
        read -r line
        if [ -z "$line" ]; then
            # Jika line kosong dan count<WORKER_COUNT, tanya apakah selesai?
            if [ $count -eq 0 ]; then
                echo -e "${RED}Data tidak boleh kosong.${NC}"
                continue
            fi
            read -p "Masih ada data? (y/n): " more
            if [[ ! "$more" =~ ^[Yy]$ ]]; then
                break
            else
                continue
            fi
        fi
        # Parse line: IP PORT PASSWORD (bisa pakai # sebagai password)
        # Format: IP PORT PASSWORD (spasi sebagai pemisah)
        set -- $line
        if [ $# -lt 3 ]; then
            echo -e "${RED}Format salah: butuh 3 kolom (IP PORT PASSWORD)${NC}"
            continue
        fi
        local ip="$1"
        local port="$2"
        # Ambil sisa sebagai password (termasuk # jika ada)
        shift 2
        local pass="$*"
        WORKER_LIST+=("$ip:$port:$pass")
        count=$((count+1))
        echo -e "${BLUE}  ➔ Ditambahkan: $ip:$port${NC}"
    done
    if [ $count -lt $WORKER_COUNT ]; then
        echo -e "${YELLOW}Jumlah worker yang dimasukkan: $count (kurang dari $WORKER_COUNT)${NC}"
        echo -e "${YELLOW}Lanjutkan dengan $count worker? (y/n):${NC}"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Instalasi dibatalkan.${NC}"
            exit 0
        fi
        WORKER_COUNT=$count
    fi
fi

# --- 6. Konfirmasi daftar worker ---
echo -e "${GREEN}=================================================${NC}"
echo -e "${YELLOW}Daftar worker yang akan disetup:${NC}"
for entry in "${WORKER_LIST[@]}"; do
    IFS=':' read -r ip port pass <<< "$entry"
    echo -e "  - IP: $ip, Port: $port"
done
echo -e "${YELLOW}Lanjutkan setup? (y/n):${NC}"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Instalasi dibatalkan.${NC}"
    exit 0
fi

# --- 7. Proses setiap worker (ssh-copy-id) dengan toleransi error ---
echo -e "${GREEN}[4/6] Menyalin SSH key ke worker (mungkin memakan waktu)...${NC}"
for entry in "${WORKER_LIST[@]}"; do
    IFS=':' read -r ip port pass <<< "$entry"
    echo -e "${BLUE}  ➔ Menyalin key ke $ip:$port...${NC}"
    if add_worker "$ip" "$port" "$pass"; then
        # sukses sudah ditambahkan ke file oleh add_worker
        :
    else
        FAILED_WORKERS+=("$ip:$port")
    fi
done

# --- 8. Buat script `run` dengan failover ---
echo -e "${GREEN}[5/6] Membuat perintah 'run'...${NC}"
cat > /usr/local/bin/run <<'EOF'
#!/bin/bash
# Perintah: run "command" - menjalankan perintah di worker secara round-robin
# Failover otomatis jika worker down

WORKER_FILE="/etc/loadbalancer/workers"
INDEX_FILE="/tmp/run_roundrobin_index"

if [ ! -f "$WORKER_FILE" ] || [ ! -s "$WORKER_FILE" ]; then
    echo "ERROR: Tidak ada worker terdaftar." >&2
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "Usage: run \"perintah dengan argumen\"" >&2
    exit 1
fi

mapfile -t WORKERS < "$WORKER_FILE"
TOTAL=${#WORKERS[@]}

# Baca index terakhir
if [ -f "$INDEX_FILE" ]; then
    LAST=$(cat "$INDEX_FILE")
    NEXT=$(( (LAST + 1) % TOTAL ))
else
    NEXT=0
fi

# Coba ke semua worker secara bergiliran sampai berhasil
for ((attempt=0; attempt<TOTAL; attempt++)); do
    WORKER="${WORKERS[$NEXT]}"
    IP=$(echo "$WORKER" | cut -d':' -f1)
    PORT=$(echo "$WORKER" | cut -d':' -f2)
    
    if ssh -p "$PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" "$@" 2>/dev/null; then
        echo "$NEXT" > "$INDEX_FILE"
        exit 0
    fi
    
    NEXT=$(( (NEXT + 1) % TOTAL ))
done

echo "ERROR: Semua worker down atau tidak bisa diakses." >&2
exit 1
EOF

chmod +x /usr/local/bin/run

# --- 9. Buat script `vt` untuk manajemen ---
echo -e "${GREEN}[6/6] Membuat perintah 'vt' (manajemen)...${NC}"
cat > /usr/local/bin/vt <<'EOF'
#!/bin/bash
# Manajemen Worker Load Balancer
# Subcommands: list, disconnect, add, help

WORKER_FILE="/etc/loadbalancer/workers"
INDEX_FILE="/tmp/run_roundrobin_index"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    cat <<HELP
${GREEN}vt - Manajemen Worker Load Balancer${NC}

Penggunaan:
  ${BLUE}vt list${NC}               - Tampilkan daftar worker dengan status & resource
  ${BLUE}vt disconnect <ID>${NC}   - Hapus worker berdasarkan ID (nomor urut)
  ${BLUE}vt add${NC}               - Tambah worker baru (interaktif)
  ${BLUE}vt help${NC}              - Tampilkan bantuan ini

Contoh:
  vt list
  vt disconnect 2
  vt add
HELP
}

check_worker() {
    local ip="$1"
    local port="$2"
    local output
    if output=$(ssh -p "$port" -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@"$ip" '
        echo "OK"
        free -h | grep -i mem | awk "{print \$2,\$3,\$4}"
        uptime -p | sed "s/up //"
        cat /proc/loadavg | awk "{print \$1,\$2,\$3}"
    ' 2>/dev/null); then
        IFS=$'\n' read -r status mem_line uptime_line load_line <<< "$output"
        if [ "$status" = "OK" ]; then
            echo "ONLINE|$mem_line|$uptime_line|$load_line"
            return 0
        fi
    fi
    echo "OFFLINE|-|-|-"
    return 1
}

cmd_list() {
    if [ ! -f "$WORKER_FILE" ] || [ ! -s "$WORKER_FILE" ]; then
        echo -e "${RED}Tidak ada worker terdaftar.${NC}"
        return 1
    fi
    
    mapfile -t WORKERS < "$WORKER_FILE"
    echo -e "${GREEN}=== Daftar Worker ===${NC}"
    printf "${BLUE}%-4s %-20s %-6s %-10s %-15s %-20s %s${NC}\n" "ID" "IP" "Port" "Status" "RAM (total/used/free)" "Uptime" "Load"
    echo "--------------------------------------------------------------------------------------------------"
    
    local id=1
    for worker in "${WORKERS[@]}"; do
        ip=$(echo "$worker" | cut -d':' -f1)
        port=$(echo "$worker" | cut -d':' -f2)
        
        info=$(check_worker "$ip" "$port")
        IFS='|' read -r status mem uptime load <<< "$info"
        
        if [ "$status" = "ONLINE" ]; then
            status_color="${GREEN}ONLINE${NC}"
        else
            status_color="${RED}OFFLINE${NC}"
            mem="-"; uptime="-"; load="-"
        fi
        
        printf "%-4s %-20s %-6s %-10b %-15s %-20s %s\n" \
            "$id" "$ip" "$port" "$status_color" "$mem" "$uptime" "$load"
        ((id++))
    done
}

cmd_disconnect() {
    local id="$1"
    if [ -z "$id" ] || ! [[ "$id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}ID harus angka positif.${NC}"
        return 1
    fi
    
    if [ ! -f "$WORKER_FILE" ] || [ ! -s "$WORKER_FILE" ]; then
        echo -e "${RED}Tidak ada worker terdaftar.${NC}"
        return 1
    fi
    
    mapfile -t WORKERS < "$WORKER_FILE"
    if [ "$id" -gt "${#WORKERS[@]}" ] || [ "$id" -lt 1 ]; then
        echo -e "${RED}ID $id tidak ditemukan.${NC}"
        return 1
    fi
    
    local new_workers=()
    local i=1
    for worker in "${WORKERS[@]}"; do
        if [ "$i" -ne "$id" ]; then
            new_workers+=("$worker")
        fi
        ((i++))
    done
    
    printf "%s\n" "${new_workers[@]}" > "$WORKER_FILE"
    rm -f "$INDEX_FILE"
    echo -e "${GREEN}Worker ID $id berhasil dihapus.${NC}"
}

cmd_add() {
    echo -e "${YELLOW}--- Tambah Worker Baru ---${NC}"
    echo -n "IP address worker: "
    read -r ip
    if [ -z "$ip" ]; then echo -e "${RED}IP tidak boleh kosong.${NC}"; return 1; fi
    
    echo -n "Port SSH worker (default 22): "
    read -r port
    if [ -z "$port" ]; then port=22; fi
    
    echo -n "Password root worker: "
    read -rs pass
    echo
    if [ -z "$pass" ]; then echo -e "${RED}Password tidak boleh kosong.${NC}"; return 1; fi
    
    if ! command -v sshpass &> /dev/null; then
        apt-get update -qq && apt-get install sshpass -y -qq
    fi
    
    echo -e "${BLUE}Menyalin key ke $ip:$port...${NC}"
    if sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -p "$port" root@"$ip"; then
        echo "$ip:$port" >> "$WORKER_FILE"
        echo -e "${GREEN}Worker $ip berhasil ditambahkan.${NC}"
    else
        echo -e "${RED}Gagal menyalin key ke $ip. Periksa koneksi dan password.${NC}"
        return 1
    fi
}

case "$1" in
    list) cmd_list ;;
    disconnect) cmd_disconnect "$2" ;;
    add) cmd_add ;;
    help|--help|-h|"") show_help ;;
    *) echo -e "${RED}Perintah tidak dikenal: $1${NC}"; show_help; exit 1 ;;
esac
EOF

chmod +x /usr/local/bin/vt

# --- 10. Tambahkan alias (tanpa sudo) ---
echo -e "${GREEN}Menambahkan alias ke .bashrc...${NC}"
for cmd in run vt; do
    if ! grep -q "alias $cmd=" ~/.bashrc 2>/dev/null; then
        echo "alias $cmd='/usr/local/bin/$cmd'" >> ~/.bashrc
    fi
done

# --- 11. Selesai ---
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}✅ INSTALASI SELESAI!${NC}"
echo -e "Perintah tersedia:"
echo -e "  ${BLUE}run \"perintah\"${NC}  - jalankan perintah di worker (round-robin, failover)"
echo -e "  ${BLUE}vt list${NC}         - lihat daftar worker & status"
echo -e "  ${BLUE}vt disconnect ID${NC} - hapus worker berdasarkan ID"
echo -e "  ${BLUE}vt add${NC}          - tambah worker baru"
echo -e "  ${BLUE}vt help${NC}         - bantuan"
echo -e "Worker terdaftar:"
if [ -s "$WORKER_FILE" ]; then
    cat "$WORKER_FILE" | while read -r line; do
        echo "  - $line"
    done
else
    echo "  (tidak ada worker yang berhasil terdaftar)"
fi
if [ ${#FAILED_WORKERS[@]} -gt 0 ]; then
    echo -e "${RED}Worker gagal (password/salah/koneksi):${NC}"
    for fw in "${FAILED_WORKERS[@]}"; do
        echo "  - $fw"
    done
fi
echo -e "${GREEN}=================================================${NC}"
echo -e "${YELLOW}Catatan:${NC}"
echo "  • Untuk memuat alias, jalankan: source ~/.bashrc"
echo "  • run akan otomatis coba worker lain jika satu down."
echo "  • vt list menampilkan resource (RAM, uptime, load)."
