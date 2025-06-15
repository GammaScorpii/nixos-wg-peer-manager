# WireGuard Peer Manager for NixOS

A comprehensive bash script for managing WireGuard peers on NixOS systems with automatic IP allocation, key management, and QR code generation for mobile devices.

## Features

- **Automatic IP Management**: Intelligent IP allocation within your WireGuard network range
- **Secure Key Storage**: Organized key management in `/etc/nixos/secrets/`
- **NixOS Integration**: Generates NixOS-compatible peer configurations
- **Mobile-Friendly**: QR code generation for easy mobile client setup
- **Safety First**: Built-in checks to prevent running as root and data corruption
- **Multiple IP Detection**: Auto-detects server public IP using multiple methods
- **Cleanup Tools**: Remove peers and clean orphaned files
- **Terminal QR Codes**: ASCII QR codes displayed directly in terminal

## Prerequisites

- NixOS system with WireGuard module configured
- `qrencode` package installed (for QR code generation)
- `wg` (WireGuard tools) installed
- Proper sudo permissions for key management

## Installation

1. Clone this repository:
```bash
git clone https://github.com/GammaScorpii/nixos-wg-peer-manager.git
cd nixos-wg-peer-manager
```

2. Make the script executable:
```bash
chmod +x wg-peer-manager.sh
```

3. Install required dependencies:
```bash
# Add to your NixOS configuration.nix
environment.systemPackages = with pkgs; [
  wireguard-tools
  qrencode
];
```

## Usage

### Add a new peer
```bash
./wg-peer-manager.sh add john-laptop
./wg-peer-manager.sh add mary-phone 10.100.0.10
./wg-peer-manager.sh add bob-tablet "" 192.168.1.100
```

### Remove a peer
```bash
./wg-peer-manager.sh remove john-laptop
```

### List all peers
```bash
./wg-peer-manager.sh list
```

### Show peer details
```bash
./wg-peer-manager.sh show john-laptop
```

### Display QR code for mobile import
```bash
./wg-peer-manager.sh qr john-laptop
```

### Manage server endpoint
```bash
./wg-peer-manager.sh endpoint
```

### Clean orphaned files
```bash
./wg-peer-manager.sh clean john-laptop
```

## Configuration

The script uses these default paths and settings:
- **WireGuard Directory**: `~/wg/`
- **Interface**: `wg0`
- **Server IP**: `10.100.0.1`
- **Network Range**: `10.100.0.0/24`
- **Port**: `51820`
- **Secrets Directory**: `/etc/nixos/secrets/wg-clients/`
- **Peers Configuration**: `/etc/nixos/modules/wg-peers.nix`

## NixOS Integration

After adding/removing peers, apply changes with:
```bash
sudo nixos-rebuild switch
```

The script generates a `wg-peers.nix` file that can be imported into your NixOS WireGuard configuration.

## Security Features

- Keys stored in protected `/etc/nixos/secrets/` directory
- Prevents execution as root user
- Secure file permissions (600 for keys, 750 for directories)
- IP address validation and conflict detection
- Safe temporary file handling

## Mobile Setup

1. Add a peer: `./wg-peer-manager.sh add my-phone`
2. Scan the QR code displayed in terminal with WireGuard mobile app
3. Connection ready!

## Contributing

Pull requests welcome! Please ensure your code follows the existing style and includes appropriate error handling.

## License

MIT License - see LICENSE file for details.

## Troubleshooting

### Common Issues

**qrencode not found**: Install with `nix-env -iA nixpkgs.qrencode` or add to system packages

**Permission denied on secrets**: Ensure you have sudo access and the secrets directory exists

**IP conflicts**: The script automatically detects and avoids IP conflicts. Use `list` command to see current allocations.

**Server endpoint detection fails**: Manually specify server IP when adding peers: `./wg-peer-manager.sh add peer "" your-server-ip`

---
