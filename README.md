# Proxy Setup (Dante + HAProxy)

## Overview
This setup provides a **SOCKS5 proxy network** using **Dante** and **HAProxy**. The system dynamically fetches and updates proxy lists, ensuring traffic is load-balanced across multiple SOCKS5 proxies for improved performance and flexibility.

## Features
- **Dante SOCKS5 Proxy** with user authentication
- **HAProxy Load Balancer** for distributing traffic across multiple proxies
- **Automatic Proxy Fetching** from TheSpeedX GitHub list
- **Auto-Detection of Network Interface** or manual override
- **Automated Proxy Updates** every 5 hours
- **Systemd Service Integration** for automatic startup

## Installation
### Prerequisites
- Ubuntu/Debian-based OS
- Root privileges

### Install & Run
```bash
wget https://example.com/setup_dante_haproxy.sh -O setup-proxy.sh
chmod +x setup_dante_haproxy.sh
sudo ./setup_dante_haproxy.sh
```

## How It Works
1. **Dante Proxy Setup:**
   - Runs on **port 1080** (SOCKS5 proxy)
   - Uses **PAM authentication** for secure user access
   - Routes traffic through **HAProxy** at `127.0.0.1:9999`

2. **HAProxy Load Balancing:**
   - Manages a pool of SOCKS5 proxies
   - Uses **round-robin distribution**
   - Proxies updated dynamically from a URL provided

3. **Automatic Proxy Updates:**
   - Fetches **fresh proxies** from TheSpeedX GitHub list
   - Updates HAProxy configuration **every 5 hours**
   - Restart services if necessary

## Usage
### Start & Check Services
```bash
systemctl restart danted
systemctl restart haproxy
systemctl status danted
systemctl status haproxy
```

### Manually Update Proxies
```bash
sudo /usr/local/bin/update_haproxy_socks.sh
```

### Add Dante Users
```bash
htpasswd -B /etc/dante.passwd <username>
```

## Security Considerations
- **Use encrypted connections** (VPNs, TLS, etc.)
- **Be cautious with public free proxies** (monitor for logs)

