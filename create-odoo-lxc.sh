#!/bin/bash
# Script para la instalación automatizada de Odoo 18.0 en Proxmox LXC con Ubuntu 24.04
# Siguiendo los pasos exactos del documento de instrucciones

# --- Configuración de colores para la interfaz ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Funciones de utilidad ---
msg() { echo -e "${BLUE}INFO: $1${NC}"; }
success() { echo -e "${GREEN}ÉXITO: $1${NC}"; }
warning() { echo -e "${YELLOW}ADVERTENCIA: $1${NC}"; }
error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
error_exit() { error "$1"; exit 1; }

# --- Función para la validación de entrada con valores por defecto ---
ask() {
    local prompt="$1"
    local default="$2"
    local validation="$3"
    local error_msg="${4:-Valor inválido, inténtelo nuevamente}"
    
    while true; do
        read -p "$(echo -e "${BLUE}$prompt [${default}]: ${NC}")" input
        input=${input:-$default}
        
        if [[ -z "$validation" ]] || [[ "$input" =~ $validation ]]; then
            echo "$input"
            return 0
        else
            warning "$error_msg"
        fi
    done
}

# --- Función para verificar y habilitar tipos de contenido en almacenamiento ---
enable_storage_content() {
    local storage="$1"
    local type="$2"
    local readable_name="$3"
    
    local storage_info=$(echo "$storage_data" | jq -r ".[] | select(.storage == \"$storage\")")
    local content=$(echo "$storage_info" | jq -r '.content // ""')
    
    if [[ "$content" != *"$type"* ]]; then
        warning "El almacenamiento '$storage' no soporta $readable_name ($type)"
        read -p "$(echo -e "${YELLOW}¿Habilitar soporte de $readable_name? (s/n): ${NC}")" enable
        if [[ "$enable" =~ ^[Ss]$ ]]; then
            pvesh set /storage/$storage --content "$content,$type" || 
                error_exit "No se pudo habilitar el soporte de $readable_name"
            success "Soporte de $readable_name habilitado para '$storage'"
            # Actualizamos la información almacenada
            storage_data=$(pvesh get /storage --output-format=json)
            return 0
        else
            error_exit "Se requiere soporte de $readable_name"
        fi
    else
        msg "El almacenamiento '$storage' ya soporta $readable_name"
        return 0
    fi
}

# --- Función para mostrar la lista de almacenamientos disponibles ---
show_storages() {
    echo -e "${BLUE}Almacenamientos disponibles:${NC}"
    local index=1
    
    for name in "${storages[@]}"; do
        local info=$(echo "$storage_data" | jq -r ".[] | select(.storage == \"$name\")")
        local content=$(echo "$info" | jq -r '.content // ""')
        local avail=$(echo "$info" | jq -r '.avail // "N/A"')
        
        # Verificar compatibilidad
        local rootdir_support="NO"
        local vztmpl_support="NO"
        [[ "$content" == *"rootdir"* ]] && rootdir_support="SÍ"
        [[ "$content" == *"vztmpl"* ]] && vztmpl_support="SÍ"
        
        # Formatear espacio disponible
        local avail_display="N/A"
        if [[ "$avail" =~ ^[0-9]+$ ]]; then
            avail_display="$(echo "scale=2; $avail/1024/1024/1024" | bc) GB"
        fi
        
        # Mostrar información del almacenamiento
        echo "$index) $name"
        echo "   Espacio disponible: $avail_display"
        echo "   Compatible con contenedores: $rootdir_support"
        echo "   Compatible con plantillas: $vztmpl_support"
        echo ""
        ((index++))
    done
}

# --- Función para crear script de instalación de Odoo ---
create_odoo_install_script() {
    local odoo_version="$1"
    local db_pass="$2"
    local admin_pass="$3"
    local odoo_user="$4"
    
    cat > /tmp/odoo_install.sh <<EOT
#!/bin/bash
# Script de instalación de Odoo $odoo_version siguiendo los pasos específicos del documento

# --- Funciones para mensajes ---
info() { echo "\033[0;34m[INFO]\033[0m \$1"; }
success() { echo "\033[0;32m[ÉXITO]\033[0m \$1"; }
warning() { echo "\033[1;33m[ADVERTENCIA]\033[0m \$1"; }
error() { echo "\033[0;31m[ERROR]\033[0m \$1"; }

# --- Paso 1: Actualizar el servidor ---
info "Actualizando el sistema..."
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# --- Paso 2: Verificar conectividad de red ---
info "Verificando conectividad de red..."
for i in {1..10}; do
    if ping -c 1 8.8.8.8 &>/dev/null; then
        success "Conectividad de red verificada"
        break
    fi
    warning "Esperando conectividad de red... intento \$i/10"
    sleep 2
    if [ \$i -eq 10 ]; then 
        error "No se pudo establecer conectividad de red"
        exit 1
    fi
done

# --- Paso 3: Asegurar el servidor ---
info "Instalando herramientas de seguridad..."
apt-get install -y openssh-server fail2ban
systemctl start fail2ban
systemctl enable fail2ban
systemctl status fail2ban

# --- Paso 4: Instalar paquetes y librerías ---
info "Instalando paquetes y librerías necesarias..."
apt-get install -y python3-pip
apt-get install -y python3-dev libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev build-essential libssl-dev libffi-dev libmysqlclient-dev libjpeg-dev libpq-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev
apt-get install -y npm
ln -sf /usr/bin/nodejs /usr/bin/node
npm install -g less less-plugin-clean-css
apt-get install -y node-less

# --- Paso 5: Configurar el servidor de base de datos ---
info "Configurando PostgreSQL..."
apt-get install -y postgresql
su - postgres -c "createuser --createdb --username postgres --no-createrole --superuser --pwprompt $odoo_user << EOF
$db_pass
$db_pass
EOF"

# --- Paso 6: Crear usuario del sistema para Odoo ---
info "Creando usuario del sistema para Odoo..."
adduser --system --home=/opt/$odoo_user --group $odoo_user

# --- Paso 7: Obtener Odoo de GitHub ---
info "Clonando el repositorio de Odoo..."
apt-get install -y git
su - $odoo_user -s /bin/bash -c "git clone https://www.github.com/odoo/odoo --depth 1 --branch $odoo_version --single-branch ."

# --- Paso 8: Instalar paquetes Python requeridos ---
info "Instalando entorno virtual y dependencias Python..."
apt-get install -y python3-venv
python3 -m venv /opt/$odoo_user/venv
cd /opt/$odoo_user/
source venv/bin/activate
pip install wheel
pip install -r requirements.txt

# Instalar wkhtmltopdf y dependencias
info "Instalando wkhtmltopdf y dependencias..."
cd /tmp
wget -q https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.bionic_amd64.deb
wget -q http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb
apt-get install -y xfonts-75dpi
dpkg -i wkhtmltox_0.12.5-1.bionic_amd64.deb || apt-get install -f -y
deactivate

# --- Paso 9: Configurar archivo de configuración ---
info "Configurando Odoo..."
mkdir -p /var/log/odoo
cp /opt/$odoo_user/debian/odoo.conf /etc/${odoo_user}.conf

# Modificar el archivo de configuración
cat > /etc/${odoo_user}.conf << EOL
[options]
admin_passwd = $admin_pass
db_host = localhost
db_port = 5432
db_user = $odoo_user
db_password = $db_pass
addons_path = /opt/$odoo_user/addons
default_productivity_apps = True
logfile = /var/log/odoo/${odoo_user}.log
EOL

chown $odoo_user: /etc/${odoo_user}.conf
chmod 640 /etc/${odoo_user}.conf
chown $odoo_user:root /var/log/odoo

# --- Paso 10: Configurar servicio systemd ---
cat > /etc/systemd/system/${odoo_user}.service << EOL
[Unit]
Description=Odoo${odoo_version}
Documentation=http://www.odoo.com

[Service]
Type=simple
User=$odoo_user
ExecStart=/opt/$odoo_user/venv/bin/python3 /opt/$odoo_user/odoo-bin -c /etc/${odoo_user}.conf

[Install]
WantedBy=default.target
EOL

chmod 755 /etc/systemd/system/${odoo_user}.service
chown root: /etc/systemd/system/${odoo_user}.service

# --- Iniciar servicio de Odoo ---
info "Iniciando servicio de Odoo..."
systemctl daemon-reload
systemctl start ${odoo_user}.service
systemctl enable ${odoo_user}.service

success "Instalación de Odoo $odoo_version completada exitosamente"
info "Para ver los logs: sudo tail -f /var/log/odoo/${odoo_user}.log"
info "Accede a Odoo en tu navegador: http://TU_IP:8069"
EOT
}

# --- Verificar requisitos previos ---
[[ "$EUID" -ne 0 ]] && error_exit "Por favor, ejecute como root (sudo $0)"
command -v pvesh >/dev/null 2>&1 || error_exit "Comando 'pvesh' no encontrado. Ejecute en Proxmox VE."
command -v pct >/dev/null 2>&1 || error_exit "Comando 'pct' no encontrado. Ejecute en Proxmox VE."

# --- Instalar dependencias ---
msg "Instalando dependencias..."
apt update && apt install -y jq curl bc || error_exit "No se pudieron instalar las dependencias"
success "Dependencias instaladas correctamente"

# --- Obtener y mostrar almacenamientos disponibles ---
msg "Obteniendo almacenamientos disponibles..."
storage_data=$(pvesh get /storage --output-format=json)
readarray -t storages < <(echo "$storage_data" | jq -r '.[].storage')
[[ ${#storages[@]} -eq 0 ]] && error_exit "No hay almacenamientos disponibles"

show_storages

# --- Seleccionar almacenamiento ---
storage_num=$(ask "Seleccione almacenamiento (número)" "1" "^[0-9]+$")
if [ "$storage_num" -lt 1 ] || [ "$storage_num" -gt "${#storages[@]}" ]; then
    error_exit "Selección de almacenamiento inválida"
fi
storage=${storages[$((storage_num-1))]}
success "Almacenamiento seleccionado: $storage"

# --- Verificar y habilitar soporte requerido ---
enable_storage_content "$storage" "rootdir" "contenedores"
enable_storage_content "$storage" "vztmpl" "plantillas"

# --- Recopilar configuración del contenedor ---
echo -e "\n${BLUE}===== CONFIGURACIÓN DEL CONTENEDOR =====${NC}"
dns_servers=$(ask "Ingrese servidores DNS (separados por coma)" "8.8.8.8,1.1.1.1")
vm_id=$(ask "ID del Contenedor (100-999)" "100" "^[1-9][0-9]{2}$" "ID inválido, debe estar entre 100-999")
hostname=$(ask "Nombre de host del contenedor" "odoo-server" "^[a-zA-Z0-9][-a-zA-Z0-9]*$" "Nombre de host inválido")
password=$(ask "Contraseña del contenedor" "odoo2024" "." "La contraseña no puede estar vacía")
memory=$(ask "RAM (MB, mín 2048)" "4096" "^[0-9]+$")
disk=$(ask "Disco (GB, mín 10)" "20" "^[0-9]+$")
cores=$(ask "Núcleos de CPU" "2" "^[0-9]+$")
ip_address=$(ask "Dirección IP" "192.168.1.100" "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" "Dirección IP inválida")
gateway=$(ask "Puerta de enlace" "192.168.1.1" "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" "Dirección de puerta de enlace inválida")

# --- Recopilar configuración de Odoo ---
echo -e "\n${BLUE}===== CONFIGURACIÓN DE ODOO =====${NC}"
odoo_version="18.0"
odoo_user=$(ask "Usuario de Odoo" "odoo18" "^[a-z][a-z0-9_-]*$" "Nombre de usuario inválido")
db_password=$(ask "Contraseña de la BD de Odoo" "odoo2024" "." "La contraseña no puede estar vacía")
admin_password=$(ask "Contraseña de administrador de Odoo" "admin2024" "." "La contraseña no puede estar vacía")

# --- Mostrar resumen de la configuración ---
echo -e "\n${BLUE}===== RESUMEN =====${NC}"
echo -e "ID: $vm_id"
echo -e "Nombre de host: $hostname"
echo -e "RAM: $memory MB"
echo -e "Disco: $disk GB"
echo -e "Núcleos: $cores"
echo -e "IP: $ip_address"

# --- Mostrar espacio disponible ---
selected_avail=$(echo "$storage_data" | jq -r ".[] | select(.storage == \"$storage\") | .avail // \"N/A\"")
if [[ "$selected_avail" =~ ^[0-9]+$ ]]; then
    selected_avail_gb=$(echo "scale=2; $selected_avail/1024/1024/1024" | bc)
    echo -e "Almacenamiento: $storage (Espacio disponible: ${selected_avail_gb} GB)"
else
    echo -e "Almacenamiento: $storage"
fi

echo -e "Versión de Odoo: $odoo_version"
echo -e "Usuario de Odoo: $odoo_user"

# --- Confirmar instalación ---
confirm=$(ask "¿Continuar? (s/n)" "s" "^[sSnN]$" "Por favor, ingrese s o n")
[[ ! "$confirm" =~ ^[Ss]$ ]] && { msg "Instalación cancelada"; exit 0; }

# --- Verificar y descargar plantilla si es necesario ---
msg "Creando contenedor LXC con Ubuntu 24.04..."
template="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
template_exists=$(pvesh get /nodes/localhost/storage/$storage/content --output-format=json | jq -r '.[] | select(.volid | endswith("'$template'"))' | wc -l)

if [[ "$template_exists" -eq 0 ]]; then
    msg "Descargando plantilla de Ubuntu 24.04..."
    pveam update || error_exit "No se pudo actualizar la lista de plantillas"
    pveam download "$storage" "$template" || error_exit "No se pudo descargar la plantilla"
    success "Plantilla descargada"
fi

# --- Crear contenedor ---
msg "Creando contenedor ID $vm_id..."
pct create "$vm_id" "$storage:vztmpl/$template" \
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
    -nameserver "$dns_servers" || error_exit "No se pudo crear el contenedor"

success "Contenedor creado"

# --- Esperar a que el contenedor se inicie ---
msg "Esperando a que el contenedor se inicie..."
network_ready=false
for i in {1..30}; do
    sleep 5
    status=$(pvesh get /nodes/localhost/lxc/$vm_id/status/current --output-format=json | jq -r '.status')
    
    if [[ "$status" == "running" ]]; then
        msg "El contenedor está en ejecución, verificando la conectividad de red..."
        if pct exec "$vm_id" -- ping -c 1 8.8.8.8 &>/dev/null; then
            network_ready=true
            msg "¡La red está disponible en el contenedor!"
            break
        else
            echo -n "."
        fi
    else
        echo -n "."
    fi
done

if [[ "$status" != "running" ]]; then
    error_exit "El contenedor no se inició a tiempo"
fi

if [[ "$network_ready" != "true" ]]; then
    warning "El contenedor se inició pero podría tener problemas de red. Continuando de todos modos..."
    sleep 10
fi

echo ""
success "Contenedor iniciado correctamente"

# --- Instalar Odoo siguiendo los pasos específicos ---
msg "Instalando Odoo $odoo_version en el contenedor $vm_id..."
create_odoo_install_script "$odoo_version" "$db_password" "$admin_password" "$odoo_user"
pct push "$vm_id" /tmp/odoo_install.sh /root/odoo_install.sh
pct exec "$vm_id" -- chmod +x /root/odoo_install.sh
pct exec "$vm_id" -- bash /root/odoo_install.sh
rm /tmp/odoo_install.sh

# --- Mostrar información final ---
echo -e "\n${GREEN}===== INSTALACIÓN COMPLETA =====${NC}"
echo -e "Odoo $odoo_version instalado en el contenedor $vm_id"
echo -e "URL: http://$ip_address:8069"
echo -e "Nombre de usuario administrador: admin"
echo -e "Contraseña de administrador: $admin_password"
echo -e "Contraseña de la BD: $db_password"
echo -e "\n${YELLOW}NOTA: Espere unos minutos para que Odoo se inicialice completamente.${NC}"