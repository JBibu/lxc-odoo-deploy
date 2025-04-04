#!/bin/bash

# Colores para la interfaz
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Funciones de mensajes
msg() { echo -e "${BLUE}INFO: $1${NC}"; }
success() { echo -e "${GREEN}ÉXITO: $1${NC}"; }
warn() { echo -e "${YELLOW}AVISO: $1${NC}"; }
error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
error_exit() { error "$1"; exit 1; }

# Validadores
check_root() { [[ "$EUID" -ne 0 ]] && error_exit "Ejecuta como root (sudo $0)"; }
check_cmd() { command -v "$1" >/dev/null 2>&1 || error_exit "Comando '$1' no instalado"; }
check_proxmox() {
    for cmd in pvesh pct pveam; do
        command -v "$cmd" >/dev/null 2>&1 || error_exit "Comando '$cmd' no disponible. Ejecutar en Proxmox VE."
    done
}

validate() {
    local type=$1 input=$2 msg=$3 min=$4 max=$5
    
    case $type in
        num)
            if ! [[ "$input" =~ ^[0-9]+$ ]]; then
                error "$msg"; return 1
            fi
            if [[ -n "$min" && -n "$max" && ($input -lt $min || $input -gt $max) ]]; then
                error "Valor fuera de rango ($min-$max)"; return 1
            fi
            ;;
        ip)
            local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
            if ! [[ $input =~ $regex ]]; then
                error "IP inválida: $input"; return 1
            fi
            IFS='.' read -r -a octets <<< "$input"
            for octet in "${octets[@]}"; do
                if [[ $octet -gt 255 ]]; then
                    error "IP inválida: $input (octeto $octet > 255)"; return 1
                fi
            done
            ;;
        empty)
            if [[ -z "$input" ]]; then
                error "$msg no puede estar vacío"; return 1
            fi
            ;;
    esac
    return 0
}

# Instalación de dependencias
install_deps() {
    msg "Verificando dependencias..."
    
    local deps=("jq" "curl")
    local missing=()
    
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Instalando: ${missing[*]}"
        apt update && apt install -y "${missing[@]}" || error_exit "No se pudieron instalar dependencias"
        success "Dependencias instaladas"
    else
        success "Dependencias OK"
    fi
}

# Gestión de almacenamiento
list_storages() {
    msg "Obteniendo almacenamientos..."
    local storages=$(pvesh get /nodes/$(hostname)/storage --output-format json | jq -r '.[].storage')
    
    [[ -z "$storages" ]] && error_exit "No hay almacenamientos disponibles"
    
    echo -e "${BLUE}Almacenamientos disponibles:${NC}"
    local i=1
    for storage in $storages; do
        echo "$i) $storage"
        storage_options[$i]=$storage
        i=$((i+1))
    done
}

check_template_storage() {
    local storage=$1
    msg "Verificando soporte de templates en '$storage'..."
    
    # Obtener contenido usando el formato JSON correcto
    local content=$(pvesh get /nodes/$(hostname)/storage/$storage/status --output-format json | jq -r '.content')
    
    if [[ "$content" != *"vztmpl"* ]]; then
        warn "Almacenamiento '$storage' sin soporte para templates"
        read -p "$(echo -e "${YELLOW}¿Habilitar? (s/n): ${NC}")" enable
        
        if [[ "$enable" =~ ^[Ss]$ ]]; then
            pvesh set /nodes/$(hostname)/storage/$storage --content "$content,vztmpl" > /dev/null 2>&1 || 
                error_exit "No se pudo habilitar soporte para templates"
            success "Soporte para templates habilitado en '$storage'"
        else
            warn "Soporte para templates no habilitado"
            return 1
        fi
    else
        success "Almacenamiento '$storage' soporta templates"
    fi
    return 0
}

# Crear contenedor LXC
create_container() {
    local vm_id=$1 hostname=$2 password=$3 memory=$4 disk=$5 cores=$6 ip=$7 gateway=$8 storage=$9
    
    msg "Creando contenedor LXC con Ubuntu 24.04..."
    
    # Verificar template storage
    check_template_storage "$storage" || 
        error_exit "Almacenamiento sin soporte para templates. Selecciona otro o habilita el soporte."
    
    # Descargar plantilla
    local template="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    local template_exists=$(pveam list "$storage" 2>/dev/null | grep -c "$template")
    
    if [[ "$template_exists" -eq 0 ]]; then
        msg "Descargando plantilla Ubuntu 24.04..."
        pveam update >/dev/null 2>&1 || error_exit "No se pudo actualizar lista de plantillas"
        
        pveam available | grep -q "ubuntu-24.04-standard" || 
            error_exit "Plantilla no encontrada. Verifica que Proxmox esté actualizado."
        
        pveam download "$storage" "$template" >/dev/null 2>&1 || 
            error_exit "No se pudo descargar la plantilla"
        
        success "Plantilla descargada en '$storage'"
    else
        success "Plantilla ya existe en '$storage'"
    fi
    
    # Verificar ID disponible
    msg "Verificando ID $vm_id..."
    if pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -q "\"vmid\":$vm_id" || 
       pvesh get /nodes/$(hostname)/lxc/$vm_id/status/current --output-format json 2>/dev/null | grep -q "status"; then
        error "ID $vm_id ya existe"
        return 1
    fi
    
    # Crear contenedor
    msg "Creando contenedor ID $vm_id..."
    pvesh create /nodes/$(hostname)/lxc \
        -vmid "$vm_id" \
        -hostname "$hostname" \
        -password "$password" \
        -ostype "ubuntu" \
        -rootfs "$storage:$disk" \
        -memory "$memory" \
        -cores "$cores" \
        -net0 "name=eth0,bridge=vmbr0,ip=$ip/24,gw=$gateway" \
        -onboot 1 \
        -start 1 \
        -unprivileged 1 \
        -features "nesting=1" \
        >/dev/null 2>&1 || error_exit "No se pudo crear el contenedor"
    
    success "Contenedor creado"
    
    # Esperar a que inicie
    msg "Esperando inicio del contenedor..."
    local timeout=60 counter=0
    
    while [[ $counter -lt $timeout ]]; do
        if pvesh get /nodes/$(hostname)/lxc/$vm_id/status/current | jq -r '.status' | grep -q "running"; then
            break
        fi
        sleep 5
        counter=$((counter + 5))
        echo -ne "${CYAN}Esperando: $counter/$timeout segundos${NC}\r"
    done
    
    [[ $counter -ge $timeout ]] && error_exit "Tiempo agotado. El contenedor no inició."
    
    echo ""
    success "Contenedor iniciado"
    sleep 10 # Esperar a que los servicios inicien
    
    return 0
}

# Instalar Odoo
install_odoo() {
    local vm_id=$1 odoo_version=$2 db_password=$3 admin_password=$4
    
    msg "Instalando Odoo $odoo_version en contenedor $vm_id..."
    
    # Script de instalación
    cat > /tmp/odoo_install.sh <<'EOF'
#!/bin/bash
apt-get update && apt-get upgrade -y
apt-get install -y python3-pip python3-dev python3-venv build-essential wget git libpq-dev poppler-utils antiword libldap2-dev libsasl2-dev libxslt1-dev node-less xfonts-75dpi xfonts-base

# wkhtmltopdf
wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb
apt-get install -f -y
rm wkhtmltox_0.12.6.1-2.jammy_amd64.deb

# Usuario Odoo
adduser --system --quiet --shell=/bin/bash --home=/opt/odoo --gecos 'Odoo' --group odoo

# PostgreSQL
apt-get install -y postgresql postgresql-client
su - postgres -c "createuser -s odoo" || true
su - postgres -c "psql -c \"ALTER USER odoo WITH PASSWORD '$1'\"" || true

# Descargar Odoo
su - odoo -c "git clone --depth 1 --branch $2 https://www.github.com/odoo/odoo /opt/odoo/odoo-server"

# Directorios
mkdir -p /opt/odoo/{custom-addons,data}
chown -R odoo:odoo /opt/odoo/{custom-addons,data}

# Entorno virtual
su - odoo -c "python3 -m venv /opt/odoo/venv"
su - odoo -c "/opt/odoo/venv/bin/pip install wheel"
su - odoo -c "cd /opt/odoo/odoo-server && /opt/odoo/venv/bin/pip install -r requirements.txt"

# Configuración
cat > /etc/odoo.conf << EOL
[options]
addons_path = /opt/odoo/odoo-server/addons,/opt/odoo/custom-addons
db_host = localhost
db_port = 5432
db_user = odoo
db_password = $1
admin_passwd = $3
data_dir = /opt/odoo/data
logfile = /var/log/odoo/odoo.log
xmlrpc_port = 8069
proxy_mode = True
EOL

# Logs
mkdir -p /var/log/odoo
chown -R odoo:odoo /var/log/odoo

# Servicio
cat > /etc/systemd/system/odoo.service << EOL
[Unit]
Description=Odoo
After=network.target postgresql.service

[Service]
Type=simple
User=odoo
Group=odoo
ExecStart=/opt/odoo/venv/bin/python3 /opt/odoo/odoo-server/odoo-bin -c /etc/odoo.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

# Iniciar servicio
systemctl daemon-reload
systemctl start odoo
systemctl enable odoo

# Nginx
apt-get install -y nginx
cat > /etc/nginx/sites-available/odoo << EOL
upstream odoo {
    server 127.0.0.1:8069;
}

server {
    listen 80;
    server_name _;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    client_max_body_size 100M;

    location / {
        proxy_pass http://odoo;
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 60m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo;
    }
}
EOL

ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

echo "Instalación completada"
EOF
    
    # Ejecutar script
    pct push "$vm_id" /tmp/odoo_install.sh /root/odoo_install.sh
    pct exec "$vm_id" -- chmod +x /root/odoo_install.sh
    pct exec "$vm_id" -- bash /root/odoo_install.sh "$db_password" "$odoo_version" "$admin_password"
    
    rm /tmp/odoo_install.sh
    success "Odoo $odoo_version instalado en contenedor $vm_id"
}

# Función para obtener input con validación
get_input() {
    local prompt="$1" type="$2" msg="$3" min="$4" max="$5"
    local input valid=1
    
    while [[ $valid -ne 0 ]]; do
        read -p "$(echo -e "${BLUE}$prompt${NC}")" input
        validate "$type" "$input" "$msg" "$min" "$max"
        valid=$?
    done
    
    echo "$input"
}

# Principal
main() {
    clear
    echo -e "${CYAN}=========================================================${NC}"
    echo -e "${CYAN}  INSTALACIÓN DE CONTENEDOR LXC CON UBUNTU 24.04 Y ODOO  ${NC}"
    echo -e "${CYAN}=========================================================${NC}"
    echo ""
    
    check_root
    check_proxmox
    install_deps
    
    # Mostrar IDs existentes
    local existing_ids=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | 
                        grep -o '"vmid":[0-9]*' | cut -d':' -f2 | sort -n | tr '\n' ' ')
    [[ -n "$existing_ids" ]] && warn "IDs ya utilizados: $existing_ids"
    
    # Listar almacenamientos
    declare -A storage_options
    list_storages
    
    # Seleccionar almacenamiento
    local storage_num
    while true; do
        storage_num=$(get_input "Selecciona almacenamiento (número): " "num" "Debe ser número" 1 "${#storage_options[@]}")
        [[ -n "${storage_options[$storage_num]}" ]] && break
        error "Selección inválida"
    done
    
    selected_storage=${storage_options[$storage_num]}
    success "Almacenamiento seleccionado: $selected_storage"
    
    echo -e "\n${CYAN}======== CONFIGURACIÓN DEL CONTENEDOR ========${NC}"
    
    # Solicitar datos
    local vm_id hostname password memory disk cores ip_address gateway
    
    while true; do
        vm_id=$(get_input "ID del contenedor (100-999): " "num" "ID debe ser número" 100 999)
        if ! pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -q "\"vmid\":$vm_id" && 
           ! pvesh get /nodes/$(hostname)/lxc/$vm_id/status/current --output-format json 2>/dev/null | grep -q "status"; then
            break
        fi
        error "ID $vm_id ya existe"
    done
    
    hostname=$(get_input "Nombre del contenedor: " "empty" "Nombre")
    password=$(get_input "Contraseña del contenedor: " "empty" "Contraseña")
    memory=$(get_input "Memoria RAM (MB, mín. 2048): " "num" "Memoria" 2048 "")
    disk=$(get_input "Espacio en disco (GB, mín. 10): " "num" "Espacio" 10 "")
    cores=$(get_input "Número de núcleos: " "num" "Núcleos" 1 "")
    ip_address=$(get_input "Dirección IP: " "ip" "")
    gateway=$(get_input "Gateway: " "ip" "")
    
    echo -e "\n${CYAN}======== CONFIGURACIÓN DE ODOO ========${NC}"
    
    odoo_version="18.0"
    msg "Se instalará Odoo versión 18.0"
    
    local db_password=$(get_input "Contraseña DB Odoo: " "empty" "Contraseña DB")
    local admin_password=$(get_input "Contraseña admin Odoo: " "empty" "Contraseña admin")
    
    # Resumen
    echo -e "\n${CYAN}======== RESUMEN ========${NC}"
    echo -e "${BLUE}ID:${NC} $vm_id"
    echo -e "${BLUE}Nombre:${NC} $hostname"
    echo -e "${BLUE}RAM:${NC} $memory MB"
    echo -e "${BLUE}Disco:${NC} $disk GB"
    echo -e "${BLUE}Núcleos:${NC} $cores"
    echo -e "${BLUE}IP:${NC} $ip_address"
    echo -e "${BLUE}Gateway:${NC} $gateway"
    echo -e "${BLUE}Almacenamiento:${NC} $selected_storage"
    echo -e "${BLUE}Odoo:${NC} $odoo_version"
    
    # Confirmación
    read -p "$(echo -e "\n${YELLOW}¿Continuar? (s/n): ${NC}")" confirm
    [[ ! "$confirm" =~ ^[Ss]$ ]] && { msg "Instalación cancelada"; exit 0; }
    
    # Instalación
    create_container "$vm_id" "$hostname" "$password" "$memory" "$disk" "$cores" "$ip_address" "$gateway" "$selected_storage"
    install_odoo "$vm_id" "$odoo_version" "$db_password" "$admin_password"
    
    # Información final
    echo -e "\n${CYAN}======== INSTALACIÓN COMPLETADA ========${NC}"
    echo -e "${GREEN}Contenedor con Odoo $odoo_version instalado.${NC}"
    echo -e "${BLUE}URL:${NC} http://$ip_address"
    echo -e "${BLUE}Usuario:${NC} admin"
    echo -e "${BLUE}Contraseña admin:${NC} $admin_password"
    echo -e "${BLUE}Contraseña DB:${NC} $db_password"
    echo -e "\n${YELLOW}NOTA: Espera unos minutos para que Odoo se inicialice completamente.${NC}"
}

main
