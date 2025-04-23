# Automated Odoo 18.0 Installer for Proxmox LXC

This script automates the installation of Odoo 18.0 on a Proxmox LXC container with Ubuntu 24.04. It handles everything from creating the container to configuring the network, installing dependencies, and setting up Odoo with PostgreSQL.

## 🚀 Quick Start

Execute the installer directly with this one-line command on your Proxmox host:

```bash
bash <(curl -s https://raw.githubusercontent.com/jbibu/lxc-odoo-deploy/main/create-odoo-lxc.py))
```

## ✨ Features

- **Fully automated** installation of Odoo 18.0 on Ubuntu 24.04 LXC
- **Interactive setup** with sensible defaults
- **Flexible networking** options (local or public IP)
- **Storage verification** to ensure container compatibility
- **Complete system configuration** including PostgreSQL, Python dependencies, and wkhtmltopdf
- **Systemd service** setup for automatic startup
- **Real-time progress** updates during installation

## 📋 Requirements

- Proxmox VE 7.0 or higher
- Root access on the Proxmox host
- Internet connectivity for downloading templates and packages
- At least 4GB RAM and 20GB storage recommended for optimal performance

## 🔧 Installation Process

The installer will guide you through the following steps:

1. **Storage Selection**: Choose which Proxmox storage to use for the container
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
   - MAC address (only for public IP)
4. **Odoo Configuration**:
   - Database user
   - Database password

After confirming your selections, the script automatically:
1. Downloads the Ubuntu 24.04 template (if needed)
2. Creates and starts the LXC container
3. Configures networking
4. Installs Odoo and all dependencies
5. Sets up the database and system services

## ✅ After Installation

Once installation is complete, you can access the web interface and continue with the Odoo setup.


## 🛠️ Manual Installation

If you prefer to download the script first:

1. Download the installation script:
   ```bash
   git clone https://github.com/JBibu/lxc-odoo-deploy.git
   ```
   
2. Enter the directory:
   ```bash
   cd lxc-odoo-deploy
   ```

3. Make it executable:
   ```bash
   chmod +x create-odoo-lxc.py
   ```

4. Run the script as root:
   ```bash
   ./create-odoo-lxc.py
   ```
   
## 📜 License

GNU General Public License v3.0
