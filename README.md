# LXC Odoo Deploy

Script that installs Odoo 18.0 on a Proxmox LXC container with Ubuntu 24.04. Handles container creation, network configuration, dependency installation, Odoo setup with PostgreSQL, and custom module installation.

## Quick Start

Run the installer directly on your Proxmox host:

```bash
python3 <(curl -s https://raw.githubusercontent.com/jbibu/lxc-odoo-deploy/main/create-odoo-lxc.py)
```

**Note**: Quick start doesn't support custom modules. For custom modules, use the manual installation method.

## Features

- Automated Odoo 18.0 installation on Ubuntu 24.04 LXC
- Interactive setup with default values
- Network options (local or public IP)
- Storage verification for container compatibility
- Complete system setup including PostgreSQL, Python dependencies, and wkhtmltopdf
- Custom module support
- Systemd service setup for automatic startup
- Progress updates during installation

## Requirements

- Proxmox VE 8.0 or higher
- Root access on Proxmox host
- Internet connection for downloads
- At least 4GB RAM and 20GB storage recommended

## Installation Process

The installer walks through these steps:

1. **Storage Selection**: Choose Proxmox storage for the container
2. **Container Configuration**:
   - Container ID (100-999)
   - Hostname
   - Root password
   - Memory allocation
   - Disk space
   - CPU cores
3. **Network Setup**:
   - Local or public IP configuration
   - IP address, netmask, gateway
   - DNS servers
   - MAC address (for public IP only)
4. **Odoo Configuration**:
   - Database user
   - Database password

After confirmation, the script automatically:
1. Downloads Ubuntu 24.04 template (if needed)
2. Creates and starts the LXC container
3. Configures networking
4. Installs Odoo, dependencies, and modules
5. Sets up database and system services

## Custom Modules

Custom modules are supported only with manual installation:

1. Clone the repository (see Manual Installation section)
2. Create a `modules` directory next to the script
3. Place custom Odoo modules in this directory
   - Each module needs its own folder with a valid `__manifest__.py` file
4. Run the installation script
5. Script will detect and install custom modules automatically

Example structure:
```
├── create-odoo-lxc.py
├── modules/
│   ├── my_custom_module1/
│   │   ├── __init__.py
│   │   ├── __manifest__.py
│   │   └── ... (other module files)
│   └── my_custom_module2/
│       ├── __init__.py
│       ├── __manifest__.py
│       └── ... (other module files)
```

Custom modules install to Odoo's `custom_addons` directory and are available after database creation. Activate them from the Apps menu in Odoo.

## After Installation

Access the web interface to continue Odoo setup.

## Manual Installation

1. Download the installation script:
   ```bash
   git clone https://github.com/JBibu/lxc-odoo-deploy.git
   ```
   
2. Enter the directory:
   ```bash
   cd lxc-odoo-deploy
   ```

3. For custom modules:
   ```bash
   mkdir -p modules
   # Copy your custom Odoo modules into the modules directory
   ```

4. Make the script executable:
   ```bash
   chmod +x create-odoo-lxc.py
   ```

5. Run as root:
   ```bash
   ./create-odoo-lxc.py
   ```

## License

GNU General Public License v3.0
