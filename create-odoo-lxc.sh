#!/bin/bash
# Script interactivo para crear un contenedor LXC con Ubuntu 24.04 en Proxmox e instalar Odoo 18
# Autor: Claude
# Fecha: 02/04/2025

# ======= COLORES =======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ======= FUNCIONES =======
function print_header() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║   Instalación de Contenedor LXC con Ubuntu 24.04 + Odoo 18    ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

function print_section() {
    echo -e "\n${BOLD}${MAGENTA}=== $1 ===${NC}\n"
}

function print_info() {
    echo -e "${BLUE}ℹ️  │ $1${NC}"
}

function print_success() {
    echo -e "${GREEN}✅ │ $1${NC}"
}

function print_warning() {
    echo -e "${YELLOW}⚠️  │ $1${NC}"
}

function print_error() {
    echo -e "${RED}❌ │ $1${NC}"
}

function ask_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    read -p "$(echo -e ${CYAN}${prompt} [${default}]: ${NC})" input
    # Si el input está vacío, usa el valor por defecto
    if [ -z "$input" ]; then
        input="$default"
    fi
    # Asigna el valor a la variable pasada por nombre
    eval "$var_name='$input'"
}

function show_help() {
    print_header
    echo -e "Este script interactivo te ayudará a crear un contenedor LXC con Ubuntu 24.04"
    echo -e "en tu servidor Proxmox y luego instalar Odoo 18 Community Edition."
    echo
    echo -e "${BOLD}Requisitos:${NC}"
    echo -e "- Tener un servidor Proxmox funcionando"
    echo -e "- Acceso root al servidor Proxmox"
    echo -e "- Conexión a Internet"
    echo
    echo -e "${BOLD}Proceso:${NC}"
    echo -e "1. Configuración del contenedor LXC"
    echo -e "2. Creación del contenedor en Proxmox"
    echo -e "3. Instalación de dependencias"
    echo -e "4. Configuración de PostgreSQL"
    echo -e "5. Instalación de Odoo 18"
    echo -e "6. Configuración del servicio"
    echo
    echo -e "${BOLD}Notas:${NC}"
    echo -e "- El script utilizará valores predeterminados que puedes modificar"
    echo -e "- Asegúrate de tener suficiente espacio en disco y memoria"
    echo -e "- La instalación puede tardar entre 5-15 minutos según tu conexión"
    echo
    read -p "$(echo -e ${BOLD}Presiona Enter para continuar...${NC})"
}

# ======= COMPROBAR PRIVILEGIOS =======
if [ "$(id -u)" -ne 0 ]; then
    print_error "Este script debe ejecutarse como root"
    exit 1
fi

# ======= COMPROBAR QUE ESTAMOS EN PROXMOX =======
if [ ! -f /usr/bin/pct ]; then
    print_error "Este script debe ejecutarse en un servidor Proxmox"
    exit 1
fi

# ======= MOSTRAR AYUDA =======
show_help

# ======= CONFIGURACIÓN INTERACTIVA =======
print_header
print_section "CONFIGURACIÓN DEL CONTENEDOR"

# Valores por defecto
DEFAULT_CONTAINER_ID="100"
DEFAULT_CONTAINER_NAME="odoo-server"
DEFAULT_CONTAINER_PASSWORD="OdooSecurePassword"
DEFAULT_STORAGE="local-lvm"
DEFAULT_MEMORY="4096"
DEFAULT_CORES="2"
DEFAULT_DISK_SIZE="20"
DEFAULT_NETWORK="vmbr0"
DEFAULT_IP_ADDRESS="dhcp"
DEFAULT_GATEWAY="auto"
DEFAULT_ODOO_DB_PASSWORD="OdooDBPassword"

# Preguntar al usuario
ask_with_default "ID del contenedor" "$DEFAULT_CONTAINER_ID" "CONTAINER_ID"
ask_with_default "Nombre del contenedor" "$DEFAULT_CONTAINER_NAME" "CONTAINER_NAME"
ask_with_default "Contraseña del contenedor" "$DEFAULT_CONTAINER_PASSWORD" "CONTAINER_PASSWORD"
ask_with_default "Almacenamiento" "$DEFAULT_STORAGE" "STORAGE"
ask_with_default "Memoria RAM (MB)" "$DEFAULT_MEMORY" "MEMORY"
ask_with_default "Núcleos de CPU" "$DEFAULT_CORES" "CORES"
ask_with_default "Tamaño del disco (GB)" "$DEFAULT_DISK_SIZE" "DISK_SIZE"
ask_with_default "Interfaz de red" "$DEFAULT_NETWORK" "NETWORK"

# Para la IP, ofrecer DHCP o manual
echo -e "${CYAN}Configuración de red:${NC}"
echo -e "1) DHCP (automático)"
echo -e "2) IP estática"
read -p "$(echo -e ${CYAN}Selecciona una opción [1]: ${NC})" ip_option
ip_option=${ip_option:-1}

if [ "$ip_option" == "1" ]; then
    IP_ADDRESS="dhcp"
    GATEWAY="auto"
else
    ask_with_default "Dirección IP (con máscara, ej: 192.168.1.100/24)" "192.168.1.100/24" "IP_ADDRESS"
    ask_with_default "Puerta de enlace" "192.168.1.1" "GATEWAY"
fi

# Contraseña para la base de datos
ask_with_default "Contraseña para la base de datos de Odoo" "$DEFAULT_ODOO_DB_PASSWORD" "ODOO_DB_PASSWORD"

# ======= CONFIRMAR CONFIGURACIÓN =======
print_section "RESUMEN DE CONFIGURACIÓN"
echo -e "${BOLD}Contenedor LXC:${NC}"
echo -e "ID: $CONTAINER_ID"
echo -e "Nombre: $CONTAINER_NAME"
echo -e "Memoria: $MEMORY MB"
echo -e "CPUs: $CORES"
echo -e "Almacenamiento: $STORAGE"
echo -e "Tamaño de disco: $DISK_SIZE GB"
echo -e "Red: $NETWORK"
if [ "$IP_ADDRESS" == "dhcp" ]; then
    echo -e "IP: DHCP (automática)"
else
    echo -e "IP: $IP_ADDRESS"
    echo -e "Gateway: $GATEWAY"
fi

echo -e "\n${BOLD}Odoo:${NC}"
echo -e "Versión: 18.0 Community Edition"
echo -e "Base de datos: PostgreSQL"

read -p "$(echo -e ${YELLOW}¿Confirmas esta configuración? (s/n): ${NC})" confirm
if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
    print_error "Instalación cancelada por el usuario"
    exit 1
fi

# ======= CREAR CONTENEDOR LXC =======
print_section "CREANDO CONTENEDOR LXC"

# Descargar la plantilla si no existe
print_info "Verificando disponibilidad de plantilla Ubuntu 24.04..."
pveam update

# Verificar el nombre exacto de la plantilla Ubuntu 24.04
TEMPLATE=$(pveam available | grep ubuntu-24.04 | head -n 1 | awk '{print $2}')

if [ -z "$TEMPLATE" ]; then
    print_error "No se encontró la plantilla de Ubuntu 24.04. Verificando todas las disponibles..."
    pveam available | grep ubuntu
    exit 1
fi

print_info "Plantilla encontrada: $TEMPLATE"

# Verificar si la plantilla ya está descargada
if [ ! -f "/var/lib/vz/template/cache/${TEMPLATE}" ]; then
    print_info "Descargando plantilla de Ubuntu 24.04..."
    pveam download local $TEMPLATE
fi

# Preparar comando de creación del contenedor
create_cmd="pct create $CONTAINER_ID local:vztmpl/$TEMPLATE \
  --hostname $CONTAINER_NAME \
  --memory $MEMORY \
  --cores $CORES \
  --swap 512 \
  --storage $STORAGE \
  --rootfs $STORAGE:$DISK_SIZE \
  --ostype ubuntu \
  --password $CONTAINER_PASSWORD \
  --unprivileged 1 \
  --features nesting=1"

# Añadir configuración de red
if [ "$IP_ADDRESS" == "dhcp" ]; then
    create_cmd="$create_cmd --net0 name=eth0,bridge=$NETWORK,ip=dhcp"
else
    create_cmd="$create_cmd --net0 name=eth0,bridge=$NETWORK,ip=$IP_ADDRESS,gw=$GATEWAY"
fi

# Crear el contenedor
print_info "Creando el contenedor LXC..."
eval $create_cmd

# Comprobar si se creó correctamente
if [ $? -ne 0 ]; then
    print_error "Error al crear el contenedor LXC"
    exit 1
fi

print_success "Contenedor LXC creado con éxito"

# Iniciar el contenedor
print_info "Iniciando el contenedor..."
pct start $CONTAINER_ID

# Esperar a que el contenedor esté listo
print_info "Esperando a que el contenedor se inicie completamente..."
sleep 20

# ======= CONFIGURAR EL CONTENEDOR E INSTALAR ODOO =======
print_section "PREPARANDO SCRIPT DE INSTALACIÓN DE ODOO"

# Crear script para ejecutar dentro del contenedor
cat > /tmp/odoo_install.sh << 'EOL'
#!/bin/bash

# Definir colores para el script dentro del contenedor
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

function print_step() {
    echo -e "\n${BOLD}${CYAN}>>> │ $1${NC}\n"
}

function print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

function print_info() {
    echo -e "${BLUE}ℹ️ $1${NC}"
}

# Paso 1: Actualizar el servidor
print_step "Paso 1: Actualizando el servidor"
apt-get update
apt-get upgrade -y
print_success "Servidor actualizado"

# Paso 2: Asegurar el servidor
print_step "Paso 2: Instalando paquetes de seguridad"
apt-get install -y openssh-server fail2ban
systemctl start fail2ban
systemctl enable fail2ban
print_success "Fail2Ban instalado y configurado"

# Paso 3: Instalar paquetes y librerías necesarias
print_step "Paso 3: Instalando paquetes y librerías necesarias"
apt-get install -y python3-pip python3-dev libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev build-essential libssl-dev libffi-dev libmysqlclient-dev libjpeg-dev libpq-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev
apt-get install -y npm
ln -sf /usr/bin/nodejs /usr/bin/node
npm install -g less less-plugin-clean-css
apt-get install -y node-less
print_success "Paquetes y librerías instalados"

# Paso 4: Configurar PostgreSQL
print_step "Paso 4: Configurando PostgreSQL"
apt-get install -y postgresql
su - postgres -c "createuser --createdb --username postgres --no-createrole --superuser --pwprompt odoo18" << EOF
$ODOO_DB_PASSWORD
$ODOO_DB_PASSWORD
EOF
print_success "PostgreSQL instalado y configurado"

# Paso 5: Crear usuario del sistema para Odoo
print_step "Paso 5: Creando usuario del sistema para Odoo"
adduser --system --home=/opt/odoo18 --group odoo18
print_success "Usuario odoo18 creado"

# Paso 6: Instalar Git y clonar el repositorio de Odoo
print_step "Paso 6: Clonando Odoo desde GitHub"
apt-get install -y git
su - odoo18 -s /bin/bash -c "git clone https://www.github.com/odoo/odoo --depth 1 --branch 18.0 --single-branch ."
print_success "Repositorio de Odoo clonado"

# Paso 7: Instalar entorno virtual y dependencias Python
print_step "Paso 7: Configurando entorno virtual Python"
apt-get install -y python3-venv
python3 -m venv /opt/odoo18/venv
cd /opt/odoo18
source venv/bin/activate
pip install -r requirements.txt

# Paso 8: Instalar wkhtmltopdf y dependencias
print_step "Paso 8: Instalando wkhtmltopdf y dependencias"
apt-get install -y xfonts-75dpi
wget https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.bionic_amd64.deb
dpkg -i wkhtmltox_0.12.5-1.bionic_amd64.deb
apt-get install -f -y
print_success "wkhtmltopdf instalado"

# Paso 9: Configurar archivo de configuración
print_step "Paso 9: Configurando Odoo"
deactivate
mkdir -p /etc
mkdir -p /var/log/odoo
touch /etc/odoo18.conf
cat > /etc/odoo18.conf << EOF
[options]
; This is the password that allows database operations:
admin_passwd = $ODOO_DB_PASSWORD
db_host = localhost
db_port = 5432
db_user = odoo18
db_password = $ODOO_DB_PASSWORD
addons_path = /opt/odoo18/addons
default_productivity_apps = True
logfile = /var/log/odoo/odoo18.log
EOF

chown odoo18: /etc/odoo18.conf
chmod 640 /etc/odoo18.conf
chown odoo18:root /var/log/odoo
print_success "Archivo de configuración de Odoo creado"

# Paso 10: Configurar Odoo como servicio
print_step "Paso 10: Configurando Odoo como servicio del sistema"
cat > /etc/systemd/system/odoo18.service << EOF
[Unit]
Description=Odoo18
Documentation=http://www.odoo.com
[Service]
Type=simple
User=odoo18
ExecStart=/opt/odoo18/venv/bin/python3 /opt/odoo18/odoo-bin -c /etc/odoo18.conf
[Install]
WantedBy=default.target
EOF

chmod 755 /etc/systemd/system/odoo18.service
chown root: /etc/systemd/system/odoo18.service
systemctl daemon-reload
systemctl start odoo18.service
systemctl enable odoo18.service
print_success "Servicio de Odoo configurado e iniciado"

# Configurar firewall (si está activo)
print_step "Paso 11: Configurando firewall"
apt-get install -y ufw
ufw allow 22/tcp
ufw allow 8069/tcp
ufw allow 8072/tcp
ufw --force enable
print_success "Firewall configurado"

# Obtenemos la IP
IP_ADDRESS=$(hostname -I | awk '{print $1}')

# Mostrar información de acceso
echo -e "\n${BOLD}${GREEN}=============================================${NC}"
echo -e "${BOLD}${GREEN}     ¡INSTALACIÓN DE ODOO 18 COMPLETADA!     ${NC}"
echo -e "${BOLD}${GREEN}=============================================${NC}"
echo -e "${BOLD}Accede a Odoo en:${NC} http://$IP_ADDRESS:8069"
echo -e "${BOLD}Base de datos:${NC} PostgreSQL"
echo -e "${BOLD}Usuario de PostgreSQL:${NC} odoo18"
echo -e "${BOLD}Contraseña de PostgreSQL:${NC} $ODOO_DB_PASSWORD"
echo -e "${BOLD}Ver logs:${NC} sudo tail -f /var/log/odoo/odoo18.log"
echo -e "${BOLD}Reiniciar Odoo:${NC} sudo systemctl restart odoo18.service"
echo -e "${BOLD}${GREEN}=============================================${NC}\n"
EOL

# Enviar el script al contenedor
print_info "Enviando script de instalación al contenedor..."
pct push $CONTAINER_ID /tmp/odoo_install.sh /tmp/odoo_install.sh

# Ejecutar el script dentro del contenedor
print_info "Ejecutando script de instalación dentro del contenedor..."
pct exec $CONTAINER_ID -- bash -c "chmod +x /tmp/odoo_install.sh && ODOO_DB_PASSWORD='$ODOO_DB_PASSWORD' /tmp/odoo_install.sh"

# Obtener la IP del contenedor
if [ "$IP_ADDRESS" == "dhcp" ]; then
    CONTAINER_IP=$(pct exec $CONTAINER_ID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
else
    CONTAINER_IP=${IP_ADDRESS%/*}
fi

print_section "INSTALACIÓN FINALIZADA"
echo -e "${BOLD}${GREEN}┌───────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${GREEN}│                                                           │${NC}"
echo -e "${BOLD}${GREEN}│  ¡El contenedor LXC con Odoo 18 ha sido creado con éxito! │${NC}"
echo -e "${BOLD}${GREEN}│                                                           │${NC}"
echo -e "${BOLD}${GREEN}└───────────────────────────────────────────────────────────┘${NC}"
echo
echo -e "${BOLD}INFORMACIÓN DEL CONTENEDOR:${NC}"
echo -e "ID: ${BOLD}$CONTAINER_ID${NC}"
echo -e "Nombre: ${BOLD}$CONTAINER_NAME${NC}"
echo -e "IP: ${BOLD}$CONTAINER_IP${NC}"
echo
echo -e "${BOLD}ACCESO A ODOO:${NC}"
echo -e "URL: ${BOLD}http://$CONTAINER_IP:8069${NC}"
echo -e "Base de datos: ${BOLD}PostgreSQL${NC}"
echo -e "Usuario PostgreSQL: ${BOLD}odoo18${NC}"
echo -e "Contraseña PostgreSQL: ${BOLD}$ODOO_DB_PASSWORD${NC}"
echo
echo -e "${BOLD}COMANDOS ÚTILES:${NC}"
echo -e "Iniciar contenedor: ${CYAN}pct start $CONTAINER_ID${NC}"
echo -e "Detener contenedor: ${CYAN}pct stop $CONTAINER_ID${NC}"
echo -e "Entrar en el contenedor: ${CYAN}pct enter $CONTAINER_ID${NC}"
echo -e "Ver logs de Odoo: ${CYAN}pct exec $CONTAINER_ID -- tail -f /var/log/odoo/odoo18.log${NC}"
echo -e "Reiniciar Odoo: ${CYAN}pct exec $CONTAINER_ID -- systemctl restart odoo18.service${NC}"
echo
print_warning "Guarda esta información en un lugar seguro."
echo
