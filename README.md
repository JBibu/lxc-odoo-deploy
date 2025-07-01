![image](https://github.com/user-attachments/assets/3b812131-5959-46bd-b866-993cd28c97c2)

This script automates the installation of Odoo 18.0 on a Proxmox LXC container with Ubuntu 24.04. It handles everything from creating the container to configuring the network, installing dependencies, setting up Odoo with PostgreSQL and installing custom modules.

## 🚀 Quick Start

Execute the installer directly with this one-line command on your Proxmox host:

```bash
python3 <(curl -s https://raw.githubusercontent.com/jbibu/lxc-odoo-deploy/main/create-odoo-lxc.py)
```

> ⚠️ **Note**: The quick start method does not support custom modules installation. If you need to install custom modules, please use the [Manual Installation](#%EF%B8%8F-manual-installation) method instead.

## ✨ Features

- **Fully automated** installation of Odoo 18.0 on Ubuntu 24.04 LXC
- **Interactive setup** with sensible defaults
- **Flexible networking** options (local or public IP)
- **Storage verification** to ensure container compatibility
- **Complete system configuration** including PostgreSQL, Python dependencies, and wkhtmltopdf
- **Custom modules support** for extra modules
- **Systemd service** setup for automatic startup
- **Real-time progress** updates during installation

## 📋 Requirements

- Proxmox VE 8.0 or higher
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
4. Installs Odoo, its dependencies and the modules
5. Sets up the database and system services

## 📦 Custom Modules

The script supports installing custom Odoo modules during the setup process, but **only when using the manual installation method**:

1. Clone the repository as described in the [Manual Installation](#%EF%B8%8F-manual-installation) section
2. Create a `modules` directory in the same location as the script
3. Place your custom Odoo modules in this directory
   - Each module should be in its own folder with a valid `__manifest__.py` file
4. Run the installation script
5. The script will automatically detect and install your custom modules

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

The custom modules will be installed in Odoo's `custom_addons` directory and will be available after creating the database. You'll need to activate them from the Apps menu in Odoo.

## ✅ After Installation

Once installation is complete, you can access the web interface and continue with the Odoo setup.


## 🛠️ Manual Installation

1. Download the installation script:
   ```bash
   git clone https://github.com/JBibu/lxc-odoo-deploy.git
   ```
   
2. Enter the directory:
   ```bash
   cd lxc-odoo-deploy
   ```

3. If you want to install custom modules:
   ```bash
   mkdir -p modules
   # Copy your custom Odoo modules into the modules directory
   ```

4. Make the script executable:
   ```bash
   chmod +x create-odoo-lxc.py
   ```

5. Run the script as root:
   ```bash
   ./create-odoo-lxc.py
   ```
   
## 📜 License

GNU General Public License v3.0
