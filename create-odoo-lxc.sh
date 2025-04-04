#!/bin/bash

#######################################################################
#                                                                     #
#  Script de Instalación de LXC Ubuntu 24.04 con Odoo en Proxmox      #
#                                                                     #
#######################################################################

# Colores para mejorar la interfaz de usuario
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Función para mostrar mensajes de error y salir
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

# Función para mostrar mensajes informativos
info_msg() {
    echo -e "${BLUE}INFO: $1${NC}"
}

# Función para mostrar mensajes de éxito
success_msg() {
    echo -e "${GREEN}ÉXITO: $1${NC}"
}

# Función para mostrar mensajes de advertencia
warn_msg() {
    echo -e "${YELLOW}ADVERTENCIA: $1${NC}"
}

# Función para comprobar si se está ejecutando como root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "Este script debe ejecutarse como root. Utiliza 'sudo $0'"
    fi
}

# Función para verificar la existencia de un comando
check_command() {
    command -v "$1" >/dev/null 2>&1 || { error_exit "El comando '$1' no está instalado. Instálalo e inténtalo de nuevo."; }
}

# Verificar comandos de Proxmox necesarios
check_proxmox_commands() {
    # Verificar comandos esenciales de Proxmox
    for cmd in pvesh pct pveam; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "El comando '$cmd' no está disponible. Este script debe ejecutarse en un servidor Proxmox VE."
        fi
    done
}

# Función para validar entradas numéricas
validate_number() {
    local input=$1
    local message=$2
    
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        error_exit "$message"
    fi
}

# Función para validar direcciones IP
validate_ip() {
    local ip=$1
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if ! [[ $ip =~ $regex ]]; then
        error_exit "Dirección IP inválida: $ip"
    fi
    
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            error_exit "Dirección IP inválida: $ip (octeto $octet > 255)"
        fi
    done
}

# Función para validar entradas de texto no vacías
validate_not_empty() {
    local input=$1
    local name=$2
    
    if [ -z "$input" ]; then
        error_exit "$name no puede estar vacío"
    fi
}

# Función para instalar dependencias necesarias
install_dependencies() {
    info_msg "Verificando e instalando dependencias necesarias en el host..."
    
    # En Proxmox, las herramientas de la API ya están instaladas
    # Solo necesitamos asegurarnos de que jq y curl estén disponibles
    local deps=("jq" "curl")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        warn_msg "Se instalarán las siguientes dependencias: ${missing_deps[*]}"
        apt update || error_exit "No se pudo actualizar los repositorios"
        apt install -y "${missing_deps[@]}" || error_exit "No se pudieron instalar las dependencias"
        success_msg "Dependencias instaladas correctamente"
    else
        success_msg "Todas las dependencias están instaladas"
    fi
}

# Función para listar almacenamientos disponibles en Proxmox
list_storages() {
    info_msg "Obteniendo almacenamientos disponibles..."
    local storages=$(pvesh get /nodes/$(hostname)/storage --type=storage | grep -v "images\|snippets\|vztmp" | jq -r '.[] | select(.active==1) | .storage')
    
    if [ -z "$storages" ]; then
        error_exit "No se encontraron almacenamientos disponibles en el host"
    fi
    
    echo -e "${BLUE}Almacenamientos disponibles:${NC}"
    local i=1
    for storage in $storages; do
        # Verificar si el almacenamiento es apto para contenedores
        local content=$(pvesh get /nodes/$(hostname)/storage/$storage | jq -r '.content')
        if [[ "$content" == *"rootdir"* ]] || [[ "$content" == *"images"* ]] || [[ "$content" == *"vztmpl"* ]]; then
            echo "$i) $storage"
            storage_options[$i]=$storage
            i=$((i+1))
        fi
    done
    
    if [ $i -eq 1 ]; then
        error_exit "No se encontraron almacenamientos adecuados para contenedores LXC"
    fi
}

# Función para verificar y habilitar el almacenamiento de templates
check_template_storage() {
    local storage=$1
    info_msg "Verificando si el almacenamiento '$storage' soporta templates de contenedores..."
    
    # Comprobar si el almacenamiento tiene habilitado el contenido vztmpl
    local content=$(pvesh get /nodes/$(hostname)/storage/$storage | jq -r '.content')
    
    if [[ "$content" != *"vztmpl"* ]]; then
        warn_msg "El almacenamiento '$storage' no tiene habilitado el soporte para templates de contenedores"
        read -p "$(echo -e "${YELLOW}¿Deseas habilitarlo? (s/n): ${NC}")" enable_templates
        
        if [[ "$enable_templates" =~ ^[Ss]$ ]]; then
            info_msg "Habilitando soporte para templates en almacenamiento '$storage'..."
            
            # Añadir 'vztmpl' al contenido del almacenamiento
            local new_content="$content,vztmpl"
            pvesh set /nodes/$(hostname)/storage/$storage --content "$new_content" > /dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                success_msg "Soporte para templates habilitado correctamente en '$storage'"
                return 0
            else
                error_exit "No se pudo habilitar el soporte para templates en '$storage'"
            fi
        else
            warn_msg "No se habilitó el soporte para templates. Se utilizará el almacenamiento local por defecto para descargar templates."
            return 1
        fi
    else
        success_msg "El almacenamiento '$storage' tiene soporte para templates de contenedores"
        return 0
    fi
}

# Función para crear un contenedor LXC
create_lxc_container() {
    local vm_id=$1
    local hostname=$2
    local password=$3
    local memory=$4
    local disk=$5
    local cores=$6
    local ip_address=$7
    local gateway=$8
    local storage=$9
    
    info_msg "Creando contenedor LXC con Ubuntu 24.04..."
    
    # Verificar si el template storage está habilitado
    local template_storage_enabled=false
    local template_storage=$storage
    
    if check_template_storage "$storage"; then
        template_storage_enabled=true
    else
        template_storage="local"
        warn_msg "Se utilizará el almacenamiento 'local' para descargar el template"
    fi
    
    # Descargar la plantilla si no existe
    local template_name="ubuntu-24.04-standard_24.04-1_amd64.tar.gz"
    local template_exists=$(pveam list "$template_storage" 2>/dev/null | grep -c "$template_name")
    
    if [ "$template_exists" -eq 0 ]; then
        info_msg "Descargando plantilla de Ubuntu 24.04 en almacenamiento '$template_storage'..."
        pveam update >/dev/null 2>&1 || error_exit "No se pudo actualizar la lista de plantillas"
        
        local template_available=$(pveam available | grep -c "ubuntu-24.04-standard")
        if [ "$template_available" -eq 0 ]; then
            error_exit "No se encontró la plantilla de Ubuntu 24.04. Verifica que Proxmox esté actualizado."
        fi
        
        pveam download "$template_storage" "$template_name" >/dev/null 2>&1 || error_exit "No se pudo descargar la plantilla en '$template_storage'"
        success_msg "Plantilla descargada correctamente en '$template_storage'"
    else
        success_msg "Ya existe una plantilla de Ubuntu 24.04 en '$template_storage'"
    fi
    
    # Verificar si el ID de VM ya existe (comprobación más robusta)
    info_msg "Verificando disponibilidad del ID $vm_id..."
    if pvesh get /cluster/resources --type vm 2>/dev/null | grep -q "\"vmid\":$vm_id"; then
        error_exit "Ya existe un contenedor o VM con ID $vm_id. Elige otro ID."
    fi
    
    # Segunda comprobación por si acaso
    if pvesh get /nodes/$(hostname)/lxc/$vm_id/status/current 2>/dev/null | grep -q "status"; then
        error_exit "Ya existe un contenedor con ID $vm_id. Elige otro ID."
    fi
    
    # Crear el contenedor
    info_msg "Creando contenedor con ID $vm_id en almacenamiento '$storage'..."
    pvesh create /nodes/$(hostname)/lxc \
        -vmid "$vm_id" \
        -hostname "$hostname" \
        -password "$password" \
        -ostype "ubuntu" \
        -rootfs "$storage:$disk" \
        -memory "$memory" \
        -cores "$cores" \
        -net0 "name=eth0,bridge=vmbr0,ip=$ip_address/24,gw=$gateway" \
        -onboot 1 \
        -start 1 \
        -unprivileged 1 \
        -features "nesting=1" \
        -storage "$storage" >/dev/null 2>&1 || error_exit "No se pudo crear el contenedor"
    
    success_msg "Contenedor creado correctamente"
    
    # Esperar a que el contenedor esté en funcionamiento
    info_msg "Esperando a que el contenedor esté en funcionamiento..."
    local timeout=60
    local counter=0
    
    while [ $counter -lt $timeout ]; do
        if pvesh get /nodes/$(hostname)/lxc/$vm_id/status/current | jq -r '.status' | grep -q "running"; then
            break
        fi
        sleep 5
        counter=$((counter + 5))
        echo -ne "${CYAN}Esperando al contenedor: $counter segundos de $timeout${NC}\r"
    done
    
    if [ $counter -ge $timeout ]; then
        error_exit "Tiempo de espera agotado. El contenedor no pudo iniciarse."
    fi
    
    echo ""
    success_msg "Contenedor en funcionamiento"
    
    # Esperar un poco más para que los servicios del sistema inicien completamente
    info_msg "Esperando a que los servicios del sistema inicien..."
    sleep 20
    
    success_msg "Contenedor LXC con Ubuntu 24.04 creado e iniciado correctamente"
}

# Función para instalar Odoo en el contenedor
install_odoo() {
    local vm_id=$1
    local odoo_version=$2
    local odoo_db_password=$3
    local odoo_admin_password=$4
    
    info_msg "Instalando Odoo $odoo_version en el contenedor $vm_id..."
    
    # Preparar el script de instalación de Odoo
    local odoo_install_script=$(cat <<EOF
#!/bin/bash

apt-get update && apt-get upgrade -y

# Instalar dependencias en el contenedor
apt-get install -y python3-pip python3-dev python3-venv build-essential wget git libpq-dev poppler-utils antiword libldap2-dev libsasl2-dev libxslt1-dev node-less xfonts-75dpi xfonts-base

# Instalar wkhtmltopdf para reportes en PDF
wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb
apt-get install -f -y
rm wkhtmltox_0.12.6.1-2.jammy_amd64.deb

# Crear usuario Odoo
adduser --system --quiet --shell=/bin/bash --home=/opt/odoo --gecos 'Odoo' --group odoo

# Instalar PostgreSQL si no está instalado
if ! command -v psql &> /dev/null; then
    apt-get install -y postgresql postgresql-client
fi

# Crear usuario de base de datos para Odoo
su - postgres -c "createuser -s odoo" || true
su - postgres -c "psql -c \"ALTER USER odoo WITH PASSWORD '$odoo_db_password'\"" || true

# Descargar Odoo
su - odoo -c "git clone --depth 1 --branch $odoo_version https://www.github.com/odoo/odoo /opt/odoo/odoo-server"

# Crear directorio para módulos personalizados
mkdir -p /opt/odoo/custom-addons
chown -R odoo:odoo /opt/odoo/custom-addons

# Crear entorno virtual Python para Odoo
su - odoo -c "python3 -m venv /opt/odoo/venv"
su - odoo -c "/opt/odoo/venv/bin/pip install wheel"
su - odoo -c "cd /opt/odoo/odoo-server && /opt/odoo/venv/bin/pip install -r requirements.txt"

# Crear archivo de configuración de Odoo
cat > /etc/odoo.conf << EOL
[options]
; Ruta al directorio de addons de Odoo
addons_path = /opt/odoo/odoo-server/addons,/opt/odoo/custom-addons

; Conexión a la base de datos PostgreSQL
db_host = localhost
db_port = 5432
db_user = odoo
db_password = $odoo_db_password
admin_passwd = $odoo_admin_password

; Configuración general
data_dir = /opt/odoo/data
logfile = /var/log/odoo/odoo.log
xmlrpc_port = 8069
proxy_mode = True
EOL

# Crear directorio para logs
mkdir -p /var/log/odoo
chown -R odoo:odoo /var/log/odoo

# Crear servicio systemd para Odoo
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

# Recargar servicios systemd
systemctl daemon-reload

# Iniciar y habilitar Odoo en el arranque
systemctl start odoo
systemctl enable odoo

# Instalar y configurar Nginx como proxy inverso
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

    # Redirigir solicitudes a Odoo
    location / {
        proxy_pass http://odoo;
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Servir archivos estáticos directamente
    location ~* /web/static/ {
        proxy_cache_valid 200 60m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo;
    }
}
EOL

# Activar el sitio de Nginx y reiniciar
ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

echo "Instalación de Odoo $odoo_version completada"
echo "Puedes acceder a Odoo a través de http://tu-ip-servidor"
echo "Usuario: admin"
echo "Contraseña administrativa del sitio: $odoo_admin_password"
echo "Contraseña de la base de datos: $odoo_db_password"
EOF
)
    
    # Ejecutar el script en el contenedor
    echo "$odoo_install_script" > /tmp/odoo_install.sh
    pct push "$vm_id" /tmp/odoo_install.sh /root/odoo_install.sh
    pct exec "$vm_id" -- chmod +x /root/odoo_install.sh
    pct exec "$vm_id" -- bash /root/odoo_install.sh
    
    # Eliminar el script temporal
    rm /tmp/odoo_install.sh
    
    success_msg "Odoo $odoo_version instalado correctamente en el contenedor $vm_id"
}

# Función principal
main() {
    clear
    echo -e "${CYAN}=========================================================${NC}"
    echo -e "${CYAN}  INSTALACIÓN DE CONTENEDOR LXC CON UBUNTU 24.04 Y ODOO  ${NC}"
    echo -e "${CYAN}=========================================================${NC}"
    echo ""
    
    # Verificar que se está ejecutando como root
    check_root
    
    # Verificar los comandos de Proxmox
    check_proxmox_commands
    
    # Verificar e instalar dependencias
    install_dependencies
    
    # Verificar la conexión a Proxmox
    check_proxmox
    
    # Verificar los IDs de contenedores existentes para informar al usuario
    info_msg "Obteniendo lista de IDs de contenedores y VMs existentes..."
    local existing_ids=$(pvesh get /cluster/resources --type vm 2>/dev/null | grep -o '"vmid":[0-9]*' | cut -d':' -f2 | sort -n | tr '\n' ' ')
    if [ ! -z "$existing_ids" ]; then
        warn_msg "IDs ya utilizados en este servidor: $existing_ids"
        echo -e "${YELLOW}Por favor, elige un ID que no esté en esta lista.${NC}"
    fi
    
    # Obtener lista de almacenamientos disponibles
    declare -A storage_options
    list_storages
    
    echo ""
    echo -e "${CYAN}========= CONFIGURACIÓN DEL CONTENEDOR LXC ==========${NC}"
    
    # Solicitar información del contenedor
    read -p "$(echo -e "${BLUE}ID del contenedor (100-999): ${NC}")" vm_id
    validate_number "$vm_id" "El ID del contenedor debe ser un número entre 100 y 999"
    if [ "$vm_id" -lt 100 ] || [ "$vm_id" -gt 999 ]; then
        error_exit "El ID del contenedor debe estar entre 100 y 999"
    fi
    
    read -p "$(echo -e "${BLUE}Nombre del contenedor: ${NC}")" hostname
    validate_not_empty "$hostname" "El nombre del contenedor"
    
    read -p "$(echo -e "${BLUE}Contraseña del contenedor: ${NC}")" password
    validate_not_empty "$password" "La contraseña del contenedor"
    
    read -p "$(echo -e "${BLUE}Memoria RAM (MB, mínimo 2048): ${NC}")" memory
    validate_number "$memory" "La memoria debe ser un número entero"
    if [ "$memory" -lt 2048 ]; then
        error_exit "La memoria mínima recomendada para Odoo es 2048 MB"
    fi
    
    read -p "$(echo -e "${BLUE}Espacio en disco (GB, mínimo 10): ${NC}")" disk
    validate_number "$disk" "El espacio en disco debe ser un número entero"
    if [ "$disk" -lt 10 ]; then
        error_exit "El espacio en disco mínimo recomendado para Odoo es 10 GB"
    fi
    
    read -p "$(echo -e "${BLUE}Número de núcleos: ${NC}")" cores
    validate_number "$cores" "El número de núcleos debe ser un número entero"
    if [ "$cores" -lt 1 ]; then
        error_exit "El número de núcleos debe ser al menos 1"
    fi
    
    read -p "$(echo -e "${BLUE}Dirección IP del contenedor: ${NC}")" ip_address
    validate_ip "$ip_address"
    
    read -p "$(echo -e "${BLUE}Dirección IP del gateway: ${NC}")" gateway
    validate_ip "$gateway"
    
    echo ""
    echo -e "${CYAN}========= CONFIGURACIÓN DE ODOO ==========${NC}"
    
    # Configurar Odoo versión 18.0
    odoo_version="18.0"
    info_msg "Se instalará Odoo versión 18.0"
    
    read -p "$(echo -e "${BLUE}Contraseña para la base de datos Odoo: ${NC}")" odoo_db_password
    validate_not_empty "$odoo_db_password" "La contraseña de la base de datos"
    
    read -p "$(echo -e "${BLUE}Contraseña administrativa de Odoo: ${NC}")" odoo_admin_password
    validate_not_empty "$odoo_admin_password" "La contraseña administrativa"
    
    # Resumen de la configuración
    echo ""
    echo -e "${CYAN}========= RESUMEN DE LA CONFIGURACIÓN ==========${NC}"
    echo -e "${BLUE}ID del contenedor:${NC} $vm_id"
    echo -e "${BLUE}Nombre del contenedor:${NC} $hostname"
    echo -e "${BLUE}Memoria RAM:${NC} $memory MB"
    echo -e "${BLUE}Espacio en disco:${NC} $disk GB"
    echo -e "${BLUE}Núcleos:${NC} $cores"
    echo -e "${BLUE}Dirección IP:${NC} $ip_address"
    echo -e "${BLUE}Gateway:${NC} $gateway"
    echo -e "${BLUE}Almacenamiento:${NC} $selected_storage"
    echo -e "${BLUE}Versión de Odoo:${NC} $odoo_version"
    echo ""
    
    # Solicitar confirmación
    read -p "$(echo -e "${YELLOW}¿Deseas proceder con la instalación? (s/n): ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
        info_msg "Instalación cancelada por el usuario"
        exit 0
    fi
    
    # Crear el contenedor LXC
    create_lxc_container "$vm_id" "$hostname" "$password" "$memory" "$disk" "$cores" "$ip_address" "$gateway" "$selected_storage"
    
    # Instalar Odoo
    install_odoo "$vm_id" "$odoo_version" "$odoo_db_password" "$odoo_admin_password"
    
    # Información final
    echo ""
    echo -e "${CYAN}========= INSTALACIÓN COMPLETADA ==========${NC}"
    echo -e "${GREEN}El contenedor LXC con Ubuntu 24.04 y Odoo $odoo_version ha sido instalado correctamente.${NC}"
    echo -e "${GREEN}Acceso a Odoo:${NC}"
    echo -e "${BLUE}URL:${NC} http://$ip_address"
    echo -e "${BLUE}Usuario por defecto:${NC} admin"
    echo -e "${BLUE}Contraseña administrativa:${NC} $odoo_admin_password"
    echo -e "${BLUE}Contraseña de base de datos:${NC} $odoo_db_password"
    echo ""
    echo -e "${YELLOW}NOTA: Es posible que necesites esperar unos minutos para que Odoo termine de inicializarse completamente.${NC}"
    echo -e "${YELLOW}Si no puedes acceder inmediatamente, intenta nuevamente en unos minutos.${NC}"
    echo ""
}

# Ejecutar la función principal
main
