#!/bin/bash
# =========================================================
# Load Balancer Proses - Eksekusi Perintah ke Worker
# Tanpa login pihak ketiga, hanya SSH + key
# =========================================================

set -e
trap 'echo -e "\n❌ Error. Script berhenti."; exit 1' ERR

# Warna
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}  Load Balancer Perintah (Round-Robin via SSH)  ${NC}"
echo -e "${GREEN}=================================================${NC}"

# --- 1. Install sshpass di utama ---
echo -e "${GREEN}[1/5] Install sshpass...${NC}"
if ! command -v sshpass &> /dev/null; then
    sudo apt update -qq && sudo apt install sshpass -y -qq
fi

# --- 2. Generate SSH key jika belum ---
echo -e "${GREEN}[2/5] Pastikan SSH key tersedia...${NC}"
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""
fi

# --- 3. Minta daftar worker ---
echo -e "${YELLOW}Masukkan jumlah VPS worker:${NC}"
read -r WORKER_COUNT
if ! [[ "$WORKER_COUNT" =~ ^[0-9]+$ ]] || [ "$WORKER_COUNT" -eq 0 ]; then
    echo -e "${RED}Jumlah worker harus angka positif!${NC}"
    exit 1
fi

# Buat direktori konfigurasi
sudo mkdir -p /etc/loadbalancer
WORKER_FILE="/etc/loadbalancer/workers"
> "$WORKER_FILE"  # kosongkan

echo -e "${GREEN}[3/5] Setup akses ke worker (ssh-copy-id)...${NC}"
for ((i=1; i<=WORKER_COUNT; i++)); do
    echo -e "${YELLOW}--- Worker ke-$i ---${NC}"
    echo -n "IP address worker: "
    read -r WORKER_IP
    echo -n "Port SSH worker (default 22): "
    read -r WORKER_PORT
    if [ -z "$WORKER_PORT" ]; then WORKER_PORT=22; fi
    echo -n "Password root worker: "
    read -rs WORKER_PASS
    echo

    # Masukkan ke file konfigurasi
    echo "$WORKER_IP:$WORKER_PORT" >> "$WORKER_FILE"

    # Copy SSH key ke worker (sekali pakai password)
    echo -e "${BLUE}  ➔ Menyalin SSH key ke $WORKER_IP:$WORKER_PORT...${NC}"
    sshpass -p "$WORKER_PASS" ssh-copy-id -o StrictHostKeyChecking=no -p "$WORKER_PORT" root@"$WORKER_IP"
    echo -e "${GREEN}  ✓ Worker $i siap${NC}"
done

# --- 4. Buat script `run` untuk eksekusi perintah ---
echo -e "${GREEN}[4/5] Membuat perintah 'run'...${NC}"
sudo tee /usr/local/bin/run > /dev/null <<'EOF'
#!/bin/bash
# Perintah: run "command" - menjalankan perintah di worker secara round-robin

WORKER_FILE="/etc/loadbalancer/workers"
INDEX_FILE="/tmp/run_roundrobin_index"

if [ ! -f "$WORKER_FILE" ] || [ ! -s "$WORKER_FILE" ]; then
    echo "ERROR: Tidak ada worker terdaftar." >&2
    exit 1
fi

# Baca semua worker ke array
mapfile -t WORKERS < "$WORKER_FILE"
TOTAL=${#WORKERS[@]}

# Baca index terakhir, increment, simpan
if [ -f "$INDEX_FILE" ]; then
    LAST=$(cat "$INDEX_FILE")
    NEXT=$(( (LAST + 1) % TOTAL ))
else
    NEXT=0
fi
echo "$NEXT" > "$INDEX_FILE"

# Pilih worker
WORKER="${WORKERS[$NEXT]}"
IP=$(echo "$WORKER" | cut -d':' -f1)
PORT=$(echo "$WORKER" | cut -d':' -f2)

# Eksekusi perintah via SSH (forward semua argumen)
if [ $# -eq 0 ]; then
    echo "Usage: run \"perintah dengan argumen\"" >&2
    exit 1
fi

ssh -p "$PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" "$@"
EOF

sudo chmod +x /usr/local/bin/run

# --- 5. Tambahkan alias ke .bashrc agar mudah dipakai ---
echo -e "${GREEN}[5/5] Menambahkan alias ke .bashrc...${NC}"
if ! grep -q "alias run=" ~/.bashrc 2>/dev/null; then
    echo "alias run='/usr/local/bin/run'" >> ~/.bashrc
fi

# --- 6. Selesai ---
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}✅ INSTALASI SELESAI!${NC}"
echo -e "Gunakan perintah: ${BLUE}run \"perintah anda\"${NC}"
echo -e "Contoh: ${BLUE}run \"python3 /root/script.py\"${NC}"
echo -e "Worker terdaftar (${#WORKERS[@]}):"
cat "$WORKER_FILE" | while read -r line; do
    echo "  - $line"
done
echo -e "${GREEN}=================================================${NC}"
echo -e "${YELLOW}Catatan:${NC}"
echo "  • Perintah akan dijalankan di worker secara bergantian (round-robin)."
echo "  • Output, error, dan exit code akan sama seperti lokal."
echo "  • Untuk memuat alias, jalankan: source ~/.bashrc"
