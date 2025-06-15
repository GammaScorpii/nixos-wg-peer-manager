# WireGuard Peer Manager for NixOS

A bash script for managing WireGuard peers on NixOS systems with automatic IP allocation, key management, and QR code generation for mobile devices. Use this script on the NixOS wireguard server to generate and manage client configs.

All the fiddly stuff which should be easy, and is, if you are used to using things like [PiVPN](https://github.com/pivpn/pivpn) and [wg-easy](https://github.com/wg-easy/wg-easy). This combines the ease of those tools on the NixOS platform, and in a way that allows the system to be reproducable as it simply edits a separate client nix module, linked to a server nix module.

## Features

- **Automatic IP Management**: Intelligent IP allocation within your WireGuard network range
- **Secure Key Creation**: Creates the private and public keys required for the clients
- **Secure Key Storage**: Organized key management in `/etc/nixos/secrets/`
- **NixOS Integration**: Generates NixOS-compatible peer configurations
- **Mobile-Friendly**: QR code generation for easy mobile client setup
- **Multiple IP Detection**: Auto-detects server public IP using multiple methods
- **Cleanup Tools**: Remove peers and clean orphaned files
- **Terminal QR Codes**: QR codes displayed directly in terminal

## Prerequisites

- NixOS system with WireGuard module configured
- `qrencode` package installed (for QR code generation)
- `wireguard-tools` package installed
- Proper sudo permissions for key management

## Installation

1. Install required dependencies (add to your NixOS configuration.nix):
```bash
environment.systemPackages = with pkgs; [
  git
  wireguard-tools
  qrencode
];
```
Rebuild:
```
sudo nixos-rebuild switch
```

2. Clone this repository:
```bash
cd ~ && \
git clone https://github.com/GammaScorpii/nixos-wg-peer-manager.git && \
cd nixos-wg-peer-manager
```

3. The script assumes you have /etc/nixos/secrets/wg-private file already set up as the servers private key. It needs to exist or be be made yourself (for now):
```bash
sudo mkdir -p /etc/nixos/secrets && \
wg genkey | sudo tee /etc/nixos/secrets/wg-private && \
sudo chmod 600 /etc/nixos/secrets/wg-private && \
sudo chown root:root /etc/nixos/secrets/wg-private
```

It also assumes the wireguard.nix module from the repo is in the /etc/nixos/modules directory. You can copy it and the wg-peers.nix template there and modify any of the default variables if you wish:
```bash
sudo mkdir -p /etc/nixos/modules && \
sudo cp ./modules/* /etc/nixos/modules/
```

And finally import wireguard.nix to your /etc/nixos/configuration.nix:
```bash
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./modules/wireguard.nix
    ];
```

4. Make the script executable:
```bash
chmod +x wg-peer-manager.sh
```


## Usage

Note: after add or remove of peers, running:

```
sudo nixos-rebuild switch
```

will apply the changes to the system, and peers will then be able to connect.

### Add a new peer
```bash
./wg-peer-manager.sh add alice-laptop
```
specify client IP
```
./wg-peer-manager.sh add alice-laptop 10.100.0.10
```
specify endpoint IP
```
./wg-peer-manager.sh add alice-laptop "" 192.168.1.100
```

### Remove a peer
```bash
./wg-peer-manager.sh remove alice-laptop
```

### List all peers
```bash
./wg-peer-manager.sh list
```

### Show peer details
```bash
./wg-peer-manager.sh show alice-laptop
```

### Display QR code for mobile import
```bash
./wg-peer-manager.sh qr alice-laptop
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

The script uses these default paths and settings, but you can change these if you like by editing the variables at the top of the wireguard.nix file:
- **WireGuard Directory**: `~/wg/`
- **Interface**: `wg0`
- **External interface** (for NAT forwarding): `eth0`
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

GNU GENERAL PUBLIC LICENSE Version 3 - see LICENSE file for details.

## Troubleshooting

### Common Issues

**qrencode not found**: Install with `nix-env -iA nixpkgs.qrencode` or add to system packages

**Permission denied on secrets**: Ensure you have sudo access and the secrets directory exists

**IP conflicts**: The script automatically detects and avoids IP conflicts. Use `list` command to see current allocations.

**Server endpoint detection fails**: Manually specify server IP when adding peers and ensure port number is correct and accessible. It can be a domain, or local IP.

```
./wg-peer-manager.sh add alice-tablet "" endpointIP
```

---
