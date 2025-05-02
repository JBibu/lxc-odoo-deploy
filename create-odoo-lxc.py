#!/usr/bin/env python3
# Script for Odoo 18.0 installation on Proxmox LXC with Ubuntu 24.04
import os, sys, json, subprocess, re, time, shutil, glob, atexit

# Color configuration
C = {
    'R': '\033[0;31m', 'G': '\033[0;32m', 'B': '\033[0;34m', 'Y': '\033[1;33m',
    'C': '\033[0;36m', 'P': '\033[0;35m', 'O': '\033[0;33m', 'N': '\033[0m', 'BOLD': '\033[1m'
}

# Utility functions
def msg(text, type_='INFO', color='B'): print(f"{C[color]}[{type_}]{C['N']} {text}")
def success(text): msg(text, 'SUCCESS', 'G')
def warning(text): msg(text, 'WARNING', 'Y')
def error(text): print(f"{C['R']}[ERROR]{C['N']} {text}", file=sys.stderr)
def error_exit(text): error(text); sys.exit(1)
def section(title): print(f"\n{C['P']}{C['BOLD']}╔═════════════════════════════════════════════════════════════════╗{C['N']}\n{C['P']}{C['BOLD']}  {title}{C['N']}\n{C['P']}{C['BOLD']}╚═════════════════════════════════════════════════════════════════╝{C['N']}")
def show_item(label, value=""): print(f"  {C['BOLD']}•{C['N']} {label} {C['C']}{value}{C['N']}")
def show_group(title): print(f"{C['BOLD']}{title}:{C['N']}")
def ask(prompt, default, validation=None, error_msg="Invalid value"):
    while True:
        user_input = input(f"{C['C']}{prompt} [{default}]: {C['N']}").strip() or default
        if validation is None or re.match(validation, user_input): return user_input
        warning(error_msg)
def confirm_action(prompt, default): 
    options = "Y/n" if default.lower().startswith('y') else "y/N"
    return (input(f"{C['G']}{prompt} ({options}): {C['N']}").strip().lower() or default.lower()).startswith('y')
def run_command(command, exit_on_error=True, show_output=False):
    try:
        result = subprocess.run(command, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if show_output: print(result.stdout)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        if exit_on_error: error_exit(f"Error: {command}\nOutput: {e.stderr}")
        return None

# NBD cleanup function
def cleanup_nbd_devices():
    """Clean up any lingering NBD devices"""
    try:
        nbd_devices = run_command("ls /dev/nbd* 2>/dev/null | grep -E '/dev/nbd[0-9]+$'", exit_on_error=False)
        if nbd_devices:
            for device in nbd_devices.split('\n'):
                if device:
                    run_command(f"qemu-nbd --disconnect {device} 2>/dev/null", exit_on_error=False)
    except:
        pass

# Register cleanup on exit
atexit.register(cleanup_nbd_devices)

# Storage functions
def get_storage_data():
    try:
        hostname = run_command("hostname")
        storage_json = run_command(f"pvesh get /nodes/{hostname}/storage --output-format=json")
        return json.loads(storage_json)
    except Exception as e: error_exit(f"Error getting storage data: {str(e)}")

def enable_storage_content(storage, content_type, readable_name, storage_data):
    storage_info = next((item for item in storage_data if item['storage'] == storage), None)
    if not storage_info: error_exit(f"Storage '{storage}' not found")

    content = storage_info.get('content', '')
    content_list = content.split(',') if content else []

    if content_type not in content_list:
        warning(f"Storage '{storage}' does not support {readable_name} ({content_type})")
        if confirm_action(f"Enable {readable_name} support?", "Y"):
            new_content = f"{content},{content_type}" if content else content_type
            run_command(f"pvesh set /storage/{storage} --content '{new_content}'")
            success(f"{readable_name} support enabled for '{storage}'")
            return get_storage_data()
        else: error_exit(f"{readable_name} support is required")
    else:
        msg(f"Storage '{storage}' already supports {readable_name}")
        return storage_data

def show_storages(storage_data, storages):
    section("AVAILABLE STORAGE")
    for index, name in enumerate(storages, 1):
        info = next((item for item in storage_data if item['storage'] == name), {})
        content = info.get('content', '')
        avail, total, used = info.get('avail', 'N/A'), info.get('total', 'N/A'), info.get('used', 'N/A')
        rootdir_support = "YES" if "rootdir" in content else "NO"
        vztmpl_support = "YES" if "vztmpl" in content else "NO"

        format_size = lambda size: f"{size/1024/1024/1024:.2f} GB" if isinstance(size, (int, float)) else "N/A"
        avail_display, total_display, used_display = format_size(avail), format_size(total), format_size(used)
        used_percent = f"{used*100/total:.2f}%" if isinstance(used, (int, float)) and isinstance(total, (int, float)) and total > 0 else "N/A"

        print(f"  {C['BOLD']}{index}) {name}{C['N']}")
        show_item("Total space", total_display)
        show_item("Used space", f"{used_display} ({used_percent})")
        show_item("Available space", avail_display)
        show_item("Container compatible", rootdir_support)
        show_item("Template compatible", vztmpl_support)
        print("")

# Check for custom modules
def check_custom_modules():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    modules_dir = os.path.join(script_dir, "modules")
    
    if not os.path.exists(modules_dir):
        msg("No 'modules' directory found")
        return [], modules_dir
    
    modules = []
    for item in os.listdir(modules_dir):
        module_path = os.path.join(modules_dir, item)
        if os.path.isdir(module_path) and os.path.exists(os.path.join(module_path, "__manifest__.py")):
            modules.append(item)
    
    return modules, modules_dir

# Create Odoo installation script
def create_odoo_install_script(odoo_version, db_pass, odoo_user, custom_modules):
    has_custom_modules = len(custom_modules) > 0
    custom_modules_str = ', '.join([f'"{m}"' for m in custom_modules])
    
    addons_path = f'/opt/odoo18/addons,/opt/odoo18/custom_addons' if has_custom_modules else f'/opt/odoo18/addons'

    script_content = f'''#!/bin/bash
# Odoo {odoo_version} installation script
info() {{ echo "[INFO] $1"; }}
success() {{ echo "[SUCCESS] $1"; }}
warning() {{ echo "[WARNING] $1"; }}
error() {{ echo "[ERROR] $1"; }}
progress() {{ echo "[PROGRESS] $1"; }}

# Update system
info "Updating system..."
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
success "System updated"

# Install requirements
info "Installing dependencies..."
progress "Installing system packages (1/5)"
apt-get install -y openssh-server fail2ban python3-pip python3-dev libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev
progress "Installing development libraries (2/5)"
apt-get install -y libldap2-dev build-essential libssl-dev libffi-dev default-libmysqlclient-dev libjpeg-dev libpq-dev
progress "Installing image processing libraries (3/5)"
apt-get install -y libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev
progress "Installing Node.js and npm (4/5)"
apt-get install -y npm git postgresql python3-venv
progress "Setting up fail2ban and Node.js (5/5)"
systemctl enable fail2ban
ln -sf /usr/bin/nodejs /usr/bin/node
npm install -g less less-plugin-clean-css
apt-get install -y node-less
success "Dependencies installed"

# Configure PostgreSQL
info "Configuring PostgreSQL..."
su - postgres -c "createuser --createdb --username postgres --no-createrole --superuser --pwprompt {odoo_user} << EOF
{db_pass}
{db_pass}
EOF"
success "PostgreSQL configured"

# Create Odoo user
info "Creating system user for Odoo..."
adduser --system --home=/opt/odoo18 --group {odoo_user}
success "System user created"

# Clone Odoo
info "Cloning Odoo repository..."
progress "Downloading Odoo source code (this may take several minutes)..."
su - {odoo_user} -s /bin/bash -c "git clone https://www.github.com/odoo/odoo --depth 1 --branch {odoo_version} --single-branch ."
success "Odoo repository cloned"

# Install Python dependencies
info "Installing Python dependencies..."
python3 -m venv /opt/odoo18/venv
cd /opt/odoo18/
progress "Installing Python requirements in virtual environment (this may take several minutes)..."
/opt/odoo18/venv/bin/pip install wheel
/opt/odoo18/venv/bin/pip install -r requirements.txt
success "Python dependencies installed"

# Install wkhtmltopdf
info "Installing wkhtmltopdf..."
apt-get install -y xfonts-75dpi xfonts-base
cd /tmp
progress "Downloading wkhtmltopdf..."
wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
progress "Installing wkhtmltopdf package..."
dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb || apt-get install -f -y
success "wkhtmltopdf installed"

'''+\
(f'''
# Install custom modules
info "Installing custom modules..."
mkdir -p /opt/odoo18/custom_addons
chown {odoo_user}: /opt/odoo18/custom_addons

# Copy custom modules to Odoo
for module in {custom_modules_str}; do
    progress "Installing module: $module"
    cp -r /tmp/custom_modules/$module /opt/odoo18/custom_addons/
done

chown -R {odoo_user}: /opt/odoo18/custom_addons/
success "Custom modules installed"
''' if has_custom_modules else '')+\
f'''

# Configure Odoo
info "Configuring Odoo..."
mkdir -p /var/log/odoo
progress "Creating configuration file..."
cat > /etc/odoo18.conf << EOL
[options]
; This is the password that allows database operations:
; admin_passwd = admin
db_host = localhost
db_port = 5432
db_user = {odoo_user}
db_password = {db_pass}
addons_path = {addons_path}
default_productivity_apps = True
logfile = /var/log/odoo/odoo18.log
EOL

chown {odoo_user}: /etc/odoo18.conf
chmod 640 /etc/odoo18.conf
chown {odoo_user}:root /var/log/odoo
progress "Creating systemd service..."

# Configure systemd
cat > /etc/systemd/system/odoo18.service << EOL
[Unit]
Description=Odoo {odoo_version}
After=network.target postgresql.service

[Service]
Type=simple
User={odoo_user}
ExecStart=/opt/odoo18/venv/bin/python3 /opt/odoo18/odoo-bin -c /etc/odoo18.conf

[Install]
WantedBy=default.target
EOL

chmod 755 /etc/systemd/system/odoo18.service
progress "Reloading systemd and starting Odoo service..."
systemctl daemon-reload
systemctl start odoo18.service
systemctl enable odoo18.service

success "Odoo {odoo_version} installation completed"
'''
    with open('/tmp/odoo_install.sh', 'w') as f:
        f.write(script_content)

# Main
def main():
    # Welcome screen
    os.system('clear')
    print(f"{C['Y']}╔═════════════════════════════════════════════════════════════════╗{C['N']}")
    print(f"{C['Y']}║            AUTOMATED ODOO INSTALLER FOR PROXMOX LXC             ║{C['N']}")
    print(f"{C['Y']}╚═════════════════════════════════════════════════════════════════╝{C['N']}\n")
    print(f"{C['C']}This script will install Odoo 18.0 on a Proxmox LXC with Ubuntu 24.04{C['N']}\n")

    if not confirm_action("Continue with installation?", "Y"):
        print(f"{C['Y']}Installation canceled.{C['N']}"); sys.exit(0)
    os.system('clear')

    # Check requirements
    section("REQUIREMENTS CHECK")
    if os.geteuid() != 0: error_exit("Please run as root")

    # Check dependencies
    msg("Checking dependencies...")
    missing_deps = [cmd for cmd in ['pvesh', 'pct', 'curl'] if shutil.which(cmd) is None]
    if missing_deps:
        warning(f"Missing: {', '.join(missing_deps)}")
        if confirm_action("Install missing dependencies?", "Y"):
            run_command(f"apt update && apt install -y {' '.join(missing_deps)}")
        else: error_exit("Dependencies required")

    # Check custom modules
    section("CUSTOM MODULES CHECK")
    custom_modules, modules_dir = check_custom_modules()
    if custom_modules:
        success(f"Found {len(custom_modules)} custom modules: {', '.join(custom_modules)}")
    else:
        warning("No custom modules found in the 'modules' directory")
        if confirm_action("Continue without custom modules?", "Y"):
            pass
        else:
            error_exit("Custom modules are required for this installation")

    # Get storage info
    msg("Getting available storage...")
    storage_data = get_storage_data()
    storages = [item['storage'] for item in storage_data]
    if not storages: error_exit("No storage available")

    show_storages(storage_data, storages)
    storage_num = int(ask("Select storage (number)", "1", r"^[0-9]+$"))
    if storage_num < 1 or storage_num > len(storages): error_exit("Invalid selection")
    storage = storages[storage_num - 1]
    success(f"Selected storage: {storage}")

    # Verify storage support
    storage_data = enable_storage_content(storage, "rootdir", "containers", storage_data)
    storage_data = enable_storage_content(storage, "vztmpl", "templates", storage_data)

    # Container config
    section("CONTAINER CONFIGURATION")
    config = {
        'vm_id': ask("Container ID (100-999)", "100", r"^[1-9][0-9]{2}$"),
        'hostname': ask("Container hostname", "odoo-server", r"^[a-zA-Z0-9][-a-zA-Z0-9]*$"),
        'password': ask("Container root password", "Cambiame123", r"."),
        'memory': ask("RAM (MB, min 2048)", "4096", r"^[0-9]+$"),
        'disk': ask("Disk (GB, min 10)", "20", r"^[0-9]+$"),
        'cores': ask("CPU cores", "2", r"^[0-9]+$"),
    }

    # Network config
    section("NETWORK CONFIGURATION")
    use_public_ip = confirm_action("Use public IP?", "N")

    # Get default network config
    try:
        default_gateway = ""
        default_interface = run_command("ip route | grep default | awk '{print $5}'", exit_on_error=False)
        if default_interface:
            default_cidr = run_command(f"ip -f inet addr show {default_interface} | grep -Po 'inet \\K[\\d.]+/[\\d]+'", exit_on_error=False)
            if default_cidr:
                ip_parts = default_cidr.split('/')[0].split('.')
                default_suggested_ip = f"{ip_parts[0]}.{ip_parts[1]}.{ip_parts[2]}.100"
                default_mask = default_cidr.split('/')[1]
                default_gateway = run_command("ip route | grep default | awk '{print $3}'", exit_on_error=False)
        else:
            default_suggested_ip, default_mask, default_gateway = "192.168.1.100", "24", "192.168.1.1"
    except:
        default_suggested_ip, default_mask, default_gateway = "192.168.1.100", "24", "192.168.1.1"

    if use_public_ip:
        config.update({
            'ip_address': ask("Public IP address", "", r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"),
            'netmask': "32",
            'gateway': ask("Gateway", default_gateway, r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"),
            'dns_servers': ask("DNS servers (comma separated)", "9.9.9.9,1.1.1.1"),
            'public_ip': True
        })

        # MAC address for public IP
        while True:
            mac = ask("MAC address for public IP", "", None)
            if mac and re.match(r'^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$', mac):
                config['mac_address'] = mac
                break
            else: error("Valid MAC address required for public IP")
    else:
        config.update({
            'ip_address': ask("Local IP address", default_suggested_ip, r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"),
            'netmask': ask("Network mask (CIDR)", default_mask, r"^[0-9]+$"),
            'gateway': ask("Gateway", default_gateway, r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"),
            'dns_servers': ask("DNS servers", "9.9.9.9,1.1.1.1"),
            'public_ip': False,
            'mac_address': None
        })

    # Odoo config
    section("ODOO CONFIGURATION")
    config.update({
        'odoo_version': "18.0",
        'odoo_user': ask("Odoo database user", "odoo18", r"^[a-z][a-z0-9_-]*$"),
        'db_password': ask("Odoo DB password", "admin2025", r"."),
    })

    # Summary
    section("CONFIGURATION SUMMARY")
    show_group("Container Info")
    show_item("ID", config['vm_id'])
    show_item("Hostname", config['hostname'])
    show_item("RAM", f"{config['memory']} MB")
    show_item("Disk", f"{config['disk']} GB")
    show_item("Cores", config['cores'])
    print("")

    show_group("Network Config")
    if config['public_ip']:
        show_item("Public IP", f"{config['ip_address']}/32")
        show_item("MAC Address", config['mac_address'])
    else:
        show_item("Local IP", f"{config['ip_address']}/{config['netmask']}")
    show_item("Gateway", config['gateway'])
    show_item("DNS", config['dns_servers'])
    print("")

    show_group("Odoo Config")
    show_item("Version", config['odoo_version'])
    show_item("User", config['odoo_user'])
    show_item("DB password", config['db_password'])
    
    if custom_modules:
        print("")
        show_group("Custom Modules")
        for module in custom_modules:
            show_item("Module", module)

    if not confirm_action("\nContinue with installation?", "Y"):
        msg("Installation canceled"); sys.exit(0)

    # Create container
    section("CONTAINER CREATION")
    msg("Creating LXC container...")
    template = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

    hostname_cmd = run_command("hostname")

    template_content_json = run_command(f"pvesh get /nodes/{hostname_cmd}/storage/{storage}/content --output-format=json")
    template_content = json.loads(template_content_json)
    template_exists = any(item.get('volid', '').endswith(template) for item in template_content)

    if not template_exists:
        msg("Downloading Ubuntu 24.04 template...")
        run_command("pveam update")
        run_command(f"pveam download {storage} {template}")
        cleanup_nbd_devices()  # Clean after template download

    # Create container command
    create_cmd = (
        f"pct create {config['vm_id']} {storage}:vztmpl/{template} "
        f"-hostname {config['hostname']} "
        f"-password {config['password']} "
        f"-ostype ubuntu "
        f"-rootfs {storage}:{config['disk']} "
        f"-memory {config['memory']} "
        f"-cores {config['cores']} "
    )

    # Network config
    if config['public_ip']:
        create_cmd += f"-net0 name=eth0,bridge=vmbr0,ip={config['ip_address']}/{config['netmask']},gw={config['gateway']},hwaddr={config['mac_address']} "
    else:
        create_cmd += f"-net0 name=eth0,bridge=vmbr0,ip={config['ip_address']}/{config['netmask']},gw={config['gateway']} "

    create_cmd += f"-onboot 1 -start 1 -unprivileged 1 -features nesting=1 -nameserver '{config['dns_servers']}'"

    run_command(create_cmd)
    success("Container created")
    cleanup_nbd_devices()  # Clean after container creation

    # Configure for public IP /32
    if config['public_ip']:
        msg("Configuring routes for public IP...")
        netplan_config = f"""# Network config for public IP
network:
  ethernets:
    eth0:
      addresses: ['{config['ip_address']}/32']
      gateway4: {config['gateway']}
      nameservers:
        addresses: [{config['dns_servers']}]
      routes:
      - scope: link
        to: {config['gateway']}/32
        via: 0.0.0.0
  version: 2
"""
        with open('/tmp/01-netcfg.yaml', 'w') as f:
            f.write(netplan_config)

        run_command(f"pct push {config['vm_id']} /tmp/01-netcfg.yaml /etc/netplan/01-netcfg.yaml")
        run_command(f"pct exec {config['vm_id']} -- chmod 644 /etc/netplan/01-netcfg.yaml")
        run_command(f"pct exec {config['vm_id']} -- bash -c 'rm -f /etc/netplan/10-*.yaml'")
        run_command(f"pct exec {config['vm_id']} -- netplan apply")
        run_command("rm /tmp/01-netcfg.yaml")

    # Wait for container to start
    msg("Waiting for container to start...")
    network_check_shown = False

    for attempt in range(30):
        time.sleep(5)

        status_json = run_command(f"pvesh get /nodes/{hostname_cmd}/lxc/{config['vm_id']}/status/current --output-format=json", exit_on_error=False)
        if status_json:
            status_data = json.loads(status_json)
            status = status_data.get('status')

            if status == "running":
                if not network_check_shown:
                    msg("Container is running, checking network connectivity...")
                    network_check_shown = True

                ping_result = run_command(f"pct exec {config['vm_id']} -- ping -c 1 8.8.8.8", exit_on_error=False)
                if ping_result is not None:
                    break

        print(".", end="", flush=True)
    print("")

    if attempt >= 29:
        warning("Network connectivity might be limited. Continuing anyway...")

    success("Network OK, container started")

    # Copy custom modules to container if available
    if custom_modules:
        section("CUSTOM MODULES SETUP")
        msg("Copying custom modules to container...")
        
        # Create a temporary directory in the container
        run_command(f"pct exec {config['vm_id']} -- mkdir -p /tmp/custom_modules")
        
        # Copy each module to the container
        for module in custom_modules:
            module_path = os.path.join(modules_dir, module)
            tmp_tar = f"/tmp/{module}.tar.gz"
            
            # Create a tar archive of the module
            run_command(f"tar -czf {tmp_tar} -C {modules_dir} {module}")
            
            # Copy the tar to the container
            run_command(f"pct push {config['vm_id']} {tmp_tar} /tmp/{module}.tar.gz")
            
            # Extract in the container
            run_command(f"pct exec {config['vm_id']} -- tar -xzf /tmp/{module}.tar.gz -C /tmp/custom_modules")
            
            # Clean up
            run_command(f"rm {tmp_tar}")
            run_command(f"pct exec {config['vm_id']} -- rm /tmp/{module}.tar.gz")
            
            success(f"Module '{module}' transferred to container")

    # Install Odoo
    section("ODOO INSTALLATION")
    msg(f"Installing Odoo {config['odoo_version']}...")
    create_odoo_install_script(config['odoo_version'], config['db_password'], config['odoo_user'], custom_modules)
    run_command(f"pct push {config['vm_id']} /tmp/odoo_install.sh /root/odoo_install.sh")
    run_command(f"pct exec {config['vm_id']} -- chmod +x /root/odoo_install.sh")

    # Execute the installation script with real-time output
    msg("Starting Odoo installation (this may take a while)...")

    try:
        process = subprocess.Popen(
            f"pct exec {config['vm_id']} -- bash /root/odoo_install.sh",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True
        )

        # Process and display the output in real-time
        for line in process.stdout:
            line = line.strip()
            if "[INFO]" in line:
                msg(line.replace("[INFO] ", ""), "INFO", "B")
            elif "[SUCCESS]" in line:
                success(line.replace("[SUCCESS] ", ""))
            elif "[WARNING]" in line:
                warning(line.replace("[WARNING] ", ""))
            elif "[ERROR]" in line:
                error(line.replace("[ERROR] ", ""))
            elif "[PROGRESS]" in line:
                msg(line.replace("[PROGRESS] ", ""), "PROGRESS", "O")
            else:
                print(f"  {line}")

        process.stdout.close()
        return_code = process.wait()

        if return_code != 0:
            warning(f"Installation process exited with code {return_code}")
        else:
            success("Odoo installation completed successfully")

    except Exception as e:
        error(f"Error during installation: {str(e)}")

    run_command("rm /tmp/odoo_install.sh")

    # Show final info
    section("INSTALLATION COMPLETED")
    print(f"{C['O']}╔═════════════════════════════════════════════════════════════════╗{C['N']}")
    print(f"{C['O']}║                    ODOO INSTALLATION COMPLETED                  ║{C['N']}")
    print(f"{C['O']}╚═════════════════════════════════════════════════════════════════╝{C['N']}")

    show_group("Odoo access information")
    show_item("URL", f"http://{config['ip_address']}:8069")
    show_item("Database user", config['odoo_user'])
    show_item("Database password", config['db_password'])
    print("")

    show_group("Container access")
    show_item("SSH Command", f"ssh root@{config['ip_address']}")
    show_item("SSH Password", config['password'])
    show_item("From Proxmox", f"pct enter {config['vm_id']}")
    
    if custom_modules:
        print("")
        show_group("Custom modules")
        for module in custom_modules:
            show_item("Module installed", module)
        
        print(f"\n{C['Y']}NOTE: Custom modules will be available after creating the database.{C['N']}")
        print(f"{C['Y']}      You'll need to activate them from the Apps menu in Odoo.{C['N']}")
        
    print(f"\n{C['Y']}NOTE: Wait a few minutes for Odoo to fully initialize.{C['N']}\n")

if __name__ == "__main__":
    main()
