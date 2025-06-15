#!/usr/bin/env bash
# WireGuard Peer Management Script for NixOS
# Usage: ./wg-peer-manager.sh [add|remove|list|show|clean|endpoint|qr] [peer-name] [optional-ip]

set -euo pipefail

# Configuration
WG_DIR="$HOME/wg"
WG_INTERFACE="wg0"
WG_SERVER_IP="10.100.0.1"
WG_NETWORK="10.100.0.0/24"
WG_PORT="51820"
NIXOS_WG_MODULE="/etc/nixos/modules/wireguard.nix"
PEERS_FILE="/etc/nixos/modules/wg-peers.nix"
SECRETS_DIR="/etc/nixos/secrets/wg-clients"
ENDPOINT_FILE="$WG_DIR/.endpoint"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
success() { echo -e "${GREEN}SUCCESS: $1${NC}" >&2; }
warning() { echo -e "${YELLOW}WARNING: $1${NC}" >&2; }
info() { echo -e "${BLUE}INFO: $1${NC}" >&2; }

# Check if running as root for some operations
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root for safety reasons."
        error "Use sudo only when prompted for specific operations."
        exit 1
    fi
}

# Helper function to check if we can read a file with sudo
can_read_file() {
    local file="$1"
    if [[ -r "$file" ]]; then
        return 0
    elif sudo test -r "$file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Helper function to safely read file (with sudo if needed)
safe_read_file() {
    local file="$1"
    if [[ -r "$file" ]]; then
        cat "$file"
    else
        sudo cat "$file"
    fi
}

# Helper function to check if we need sudo for directory operations
ensure_secrets_dir() {
    if [[ ! -d "$SECRETS_DIR" ]]; then
        info "Creating secrets directory: $SECRETS_DIR"
        sudo mkdir -p "$SECRETS_DIR"
        sudo chmod 700 "$SECRETS_DIR"
    elif [[ ! -w "$SECRETS_DIR" ]]; then
        # Directory exists but we can't write to it
        return 1
    fi
    return 0
}

# Initialize directories
init_dirs() {
    mkdir -p "$WG_DIR"
    chmod 750 "$WG_DIR"
    
    # Ensure secrets directory exists
    if ! ensure_secrets_dir; then
        warning "Cannot write to secrets directory, will need sudo for key operations"
    fi
    
    # Ensure modules directory exists
    if [[ ! -d "$(dirname "$PEERS_FILE")" ]]; then
        info "Creating modules directory: $(dirname "$PEERS_FILE")"
        sudo mkdir -p "$(dirname "$PEERS_FILE")"
    fi
}

# Get server endpoint (IP:PORT) - FIXED: Proper I/O handling
get_server_endpoint() {
    local override_ip="$1"
    local endpoint=""
    
    # If override provided, use it
    if [[ -n "$override_ip" ]]; then
        endpoint="$override_ip:$WG_PORT"
        echo "$endpoint" > "$ENDPOINT_FILE"
        echo "$endpoint"
        return
    fi
    
    # Check if we have a saved endpoint
    if [[ -f "$ENDPOINT_FILE" ]]; then
        local saved_endpoint
        saved_endpoint=$(cat "$ENDPOINT_FILE")
        echo -n "Use saved endpoint '$saved_endpoint'? [Y/n]: " >&2
        read -r response
        if [[ "$response" =~ ^[Nn]$ ]]; then
            rm -f "$ENDPOINT_FILE"
        else
            echo "$saved_endpoint"
            return
        fi
    fi
    
    info "Detecting server public IP..."
    
    # Try multiple methods to get public IP
    local detected_ip=""
    local methods=(
        "curl -s -4 https://icanhazip.com"
        "curl -s -4 https://ipinfo.io/ip"
        "curl -s -4 https://api.ipify.org"
        "dig +short myip.opendns.com @resolver1.opendns.com"
    )
    
    for method in "${methods[@]}"; do
        if command -v "${method%% *}" >/dev/null 2>&1; then
            detected_ip=$(eval "$method" 2>/dev/null | tr -d '\n\r' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | head -1)
            if [[ -n "$detected_ip" ]]; then
                info "Detected public IP: $detected_ip"
                break
            fi
        fi
    done
    
    # If auto-detection failed, prompt for manual input
    if [[ -z "$detected_ip" ]]; then
        warning "Could not auto-detect public IP"
        echo -n "Please enter your server's public IP address: " >&2
        read -r manual_ip
        if [[ "$manual_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            detected_ip="$manual_ip"
        else
            error "Invalid IP address format"
            exit 1
        fi
    else
        # Confirm the detected IP
        echo -n "Use detected IP '$detected_ip'? [Y/n]: " >&2
        read -r response
        if [[ "$response" =~ ^[Nn]$ ]]; then
            echo -n "Please enter your server's public IP address: " >&2
            read -r manual_ip
            if [[ "$manual_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                detected_ip="$manual_ip"
            else
                error "Invalid IP address format"
                exit 1
            fi
        fi
    fi
    
    endpoint="$detected_ip:$WG_PORT"
    
    # Save the endpoint for future use
    echo "$endpoint" > "$ENDPOINT_FILE"
    chmod 600 "$ENDPOINT_FILE"
    
    echo "$endpoint"
}

# Get next available IP address
get_next_ip() {
    local used_ips=()
    local ip_cache_file="$WG_DIR/used-ips.txt"
    
    info "Checking for used IP addresses..."
    
    # Method 0: IPs from cache file
    if [[ -f "$ip_cache_file" ]]; then
        while IFS= read -r ip; do
            if [[ "$ip" =~ ^10\.100\.0\.[0-9]+$ ]]; then
                used_ips+=("$ip")
                info "Found used IP from cache: $ip"
            fi
        done < "$ip_cache_file"
    fi
    
    # Method 1: Check peer directories
    if [[ -d "$WG_DIR" ]]; then
        for peer_dir in "$WG_DIR"/*; do
            if [[ -d "$peer_dir" ]]; then
                local ip_file="$peer_dir/ip.txt"
                if [[ -f "$ip_file" ]]; then
                    local ip
                    ip=$(cat "$ip_file")
                    if [[ "$ip" =~ ^10\.100\.0\.[0-9]+$ ]]; then
                        used_ips+=("$ip")
                        info "Found used IP from peer directory: $ip"
                    fi
                fi
            fi
        done
    fi
    
    # Method 2: Check peers file
    if [[ -f "$PEERS_FILE" ]] && can_read_file "$PEERS_FILE"; then
        while IFS= read -r line; do
            if [[ $line =~ allowedIPs[[:space:]]*=[[:space:]]*\[[[:space:]]*\"([0-9.]+)/32\" ]]; then
                local ip="${BASH_REMATCH[1]}"
                if [[ "$ip" =~ ^10\.100\.0\.[0-9]+$ ]]; then
                    used_ips+=("$ip")
                    info "Found used IP from peers file: $ip"
                fi
            fi
        done < <(safe_read_file "$PEERS_FILE")
    fi
    
    # Method 3: Active wg interface
    if command -v wg >/dev/null 2>&1; then
        if wg_output=$(sudo wg show "$WG_INTERFACE" 2>/dev/null); then
            while IFS= read -r line; do
                if [[ $line =~ allowed\ ips:.*([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/32 ]]; then
                    local ip="${BASH_REMATCH[1]}"
                    if [[ "$ip" =~ ^10\.100\.0\.[0-9]+$ ]]; then
                        used_ips+=("$ip")
                        info "Found used IP from active WireGuard: $ip"
                    fi
                fi
            done <<< "$wg_output"
        fi
    fi
    
    # Always reserve 10.100.0.1 for server
    used_ips+=("10.100.0.1")
    
    # Deduplicate
    mapfile -t used_ips < <(printf '%s\n' "${used_ips[@]}" | sort -u)
    
    info "Total used IPs: ${#used_ips[@]}"
    
    # Find next available
    for i in {2..254}; do
        local candidate_ip="10.100.0.$i"
        local found=false
        for used in "${used_ips[@]}"; do
            if [[ "$used" == "$candidate_ip" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            info "Next available IP: $candidate_ip"
            echo "$candidate_ip"
            return
        fi
    done
    
    error "No available IP addresses in range 10.100.0.2-254"
    exit 1
}

# Create client config
create_client_config() {
    local peer_name="$1"
    local peer_ip="$2"
    local endpoint="$3"
    local private_key_file="$SECRETS_DIR/$peer_name-private"
    local config_file="$WG_DIR/$peer_name.conf"
    
    # Get server public key
    local server_public_key
    local server_private_key_file="/etc/nixos/secrets/wg-private"
    
    if can_read_file "$server_private_key_file"; then
        server_public_key=$(safe_read_file "$server_private_key_file" | wg pubkey)
    else
        error "Cannot read server private key at $server_private_key_file"
        error "Please ensure the file exists and you have proper permissions"
        exit 1
    fi
    
    # Get the private key content
    local private_key_content
    if can_read_file "$private_key_file"; then
        private_key_content=$(safe_read_file "$private_key_file")
    else
        error "Cannot read private key file: $private_key_file"
        exit 1
    fi
    
    cat > "$config_file" << EOF
[Interface]
PrivateKey = $private_key_content
Address = $peer_ip/24
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = $server_public_key
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    chmod 600 "$config_file"
    success "Client config created: $config_file"
    info "Endpoint set to: $endpoint"
}

# Update peers file
update_peers_file() {
    local temp_file
    temp_file=$(mktemp)
    
    echo "# Auto-generated WireGuard peers configuration" > "$temp_file"
    echo "# Managed by wg-peer-manager.sh" >> "$temp_file"
    echo "[" >> "$temp_file"
    
    # Add all existing peer configs by reading from peer directories
    if [[ -d "$WG_DIR" ]]; then
        for peer_dir in "$WG_DIR"/*; do
            if [[ -d "$peer_dir" ]]; then
                local peer_name
                peer_name=$(basename "$peer_dir")
                local ip_file="$peer_dir/ip.txt"
                local public_key_file="$SECRETS_DIR/$peer_name-public"
                
                # Skip if this is not a valid peer directory
                if [[ ! -f "$ip_file" ]]; then
                    continue
                fi
                
                # Check if public key exists
                if ! sudo test -f "$public_key_file" 2>/dev/null; then
                    warning "Public key missing for peer $peer_name, skipping"
                    continue
                fi
                
                local public_key
                local peer_ip
                public_key=$(safe_read_file "$public_key_file")
                peer_ip=$(cat "$ip_file")
                
                cat >> "$temp_file" << EOF
  { # $peer_name
    publicKey = "$public_key";
    allowedIPs = [ "$peer_ip/32" ];
  }
EOF
            fi
        done
    fi
    
    echo "]" >> "$temp_file"
    
    # Ensure the directory exists
    sudo mkdir -p "$(dirname "$PEERS_FILE")"
    
    # Move to final location (requires sudo)
    sudo mv "$temp_file" "$PEERS_FILE"
    sudo chmod 644 "$PEERS_FILE"
    
    info "Updated peers file: $PEERS_FILE"
}

# Add peer - FIXED: Proper IP caching
add_peer() {
    local peer_name="$1"
    local peer_ip="${2:-$(get_next_ip)}"
    local override_endpoint="$3"
    local peer_dir="$WG_DIR/$peer_name"
    local private_key_file="$SECRETS_DIR/$peer_name-private"
    local public_key_file="$SECRETS_DIR/$peer_name-public"
    
    # FIXED: Track assigned IP in cache immediately after assignment
    local ip_cache_file="$WG_DIR/used-ips.txt"
    echo "$peer_ip" >> "$ip_cache_file"
    sort -u "$ip_cache_file" -o "$ip_cache_file"
    
    # Check what already exists
    local dir_exists=false
    local keys_exist=false
    
    if [[ -d "$peer_dir" ]]; then
        dir_exists=true
    fi
    
    # Check for existing keys using sudo if needed
    if sudo test -f "$private_key_file" 2>/dev/null || sudo test -f "$public_key_file" 2>/dev/null; then
        keys_exist=true
    fi
    
    if [[ "$dir_exists" == true ]] || [[ "$keys_exist" == true ]]; then
        error "Peer '$peer_name' already exists"
        if [[ "$dir_exists" == true ]]; then
            info "Directory exists: $peer_dir"
        fi
        if sudo test -f "$private_key_file" 2>/dev/null; then
            info "Private key exists: $private_key_file"
        fi
        if sudo test -f "$public_key_file" 2>/dev/null; then
            info "Public key exists: $public_key_file"
        fi
        info "Use '$0 remove $peer_name' to remove existing peer first"
        exit 1
    fi
    
    info "Adding peer: $peer_name with IP: $peer_ip"
    
    # Get server endpoint
    local endpoint
    endpoint=$(get_server_endpoint "$override_endpoint")
    
    # Create peer directory in ~/wg
    mkdir -p "$peer_dir"
    chmod 750 "$peer_dir"
    
    # Generate keys in secrets directory (always requires sudo)
    info "Generating keys (requires sudo)..."
    sudo bash -c "wg genkey | tee '$private_key_file' | wg pubkey > '$public_key_file'"
    sudo chmod 600 "$private_key_file"
    sudo chmod 600 "$public_key_file"
    
    # Store IP in peer directory
    echo "$peer_ip" > "$peer_dir/ip.txt"
    
    # Create client config
    create_client_config "$peer_name" "$peer_ip" "$endpoint"
    
    # Update peers configuration
    update_peers_file
    
    success "Peer '$peer_name' added successfully"
    info "Keys created:"
    info "  Private: $private_key_file"
    info "  Public: $public_key_file"
    info "Client config: $WG_DIR/$peer_name.conf"
    info "Server endpoint: $endpoint"
    
    # Show QR code for easy mobile import
    echo ""
    info "QR Code for mobile import:"
    show_qr "$peer_name" "quiet"

    info "To apply changes, run: sudo nixos-rebuild switch"
}

# Remove peer - FIXED: Update IP cache on removal
remove_peer() {
    local peer_name="$1"
    local peer_dir="$WG_DIR/$peer_name"
    local private_key_file="$SECRETS_DIR/$peer_name-private"
    local public_key_file="$SECRETS_DIR/$peer_name-public"
    local ip_cache_file="$WG_DIR/used-ips.txt"
    
    # Check if peer exists (check both locations)
    local peer_exists=false
    if [[ -d "$peer_dir" ]]; then
        peer_exists=true
    fi
    if sudo test -f "$private_key_file" 2>/dev/null; then
        peer_exists=true
    fi
    
    if [[ "$peer_exists" == false ]]; then
        error "Peer '$peer_name' does not exist"
        exit 1
    fi
    
    warning "Removing peer: $peer_name"
    
    # Remove IP from cache if it exists
    if [[ -f "$peer_dir/ip.txt" ]]; then
        local peer_ip
        peer_ip=$(cat "$peer_dir/ip.txt")
        if [[ -f "$ip_cache_file" ]]; then
            grep -v "^$peer_ip$" "$ip_cache_file" > "$ip_cache_file.tmp" && mv "$ip_cache_file.tmp" "$ip_cache_file"
            info "Removed IP $peer_ip from cache"
        fi
    fi
    
    # Remove peer directory
    if [[ -d "$peer_dir" ]]; then
        rm -rf "$peer_dir"
        info "Removed directory: $peer_dir"
    fi
    
    # Remove keys from secrets directory (requires sudo)
    if sudo test -f "$private_key_file" 2>/dev/null; then
        sudo rm -f "$private_key_file"
        info "Removed private key: $private_key_file"
    fi
    
    if sudo test -f "$public_key_file" 2>/dev/null; then
        sudo rm -f "$public_key_file"
        info "Removed public key: $public_key_file"
    fi
    
    # Remove config file
    local config_file="$WG_DIR/$peer_name.conf"
    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        info "Removed config file: $config_file"
    fi
    
    # Update peers configuration
    update_peers_file
    
    success "Peer '$peer_name' removed successfully"
    info "To apply changes, run: sudo nixos-rebuild switch"
}

# List peers
list_peers() {
    echo "Current WireGuard peers:"
    echo "======================="
    
    local found_peers=false
    
    # Check for peers in ~/wg directory
    if [[ -d "$WG_DIR" ]]; then
        for peer_dir in "$WG_DIR"/*; do
            if [[ -d "$peer_dir" ]]; then
                local peer_name
                peer_name=$(basename "$peer_dir")
                local ip_file="$peer_dir/ip.txt"
                
                if [[ -f "$ip_file" ]]; then
                    local peer_ip
                    peer_ip=$(cat "$ip_file")
                    printf "%-20s %s\n" "$peer_name" "$peer_ip"
                    found_peers=true
                fi
            fi
        done
    fi
    
    # Also check for orphaned keys in secrets directory
    if [[ -d "$SECRETS_DIR" ]]; then
        echo ""
        echo "Keys in secrets directory:"
        echo "=========================="
        local found_keys=false
        
        # Use sudo find to handle permissions
        while IFS= read -r -d '' key_file; do
            local peer_name
            peer_name=$(basename "$key_file" -private)
            local peer_dir="$WG_DIR/$peer_name"
            
            if [[ ! -d "$peer_dir" ]]; then
                printf "%-20s %s\n" "$peer_name" "(orphaned - no config dir)"
                found_keys=true
            fi
        done < <(sudo find "$SECRETS_DIR" -name "*-private" -type f -print0 2>/dev/null)
        
        if [[ "$found_keys" == false ]]; then
            info "No orphaned keys found"
        fi
    fi
    
    if [[ "$found_peers" == false ]]; then
        info "No active peers configured"
    fi
}

# Show peer details
show_peer() {
    local peer_name="$1"
    local peer_dir="$WG_DIR/$peer_name"
    local private_key_file="$SECRETS_DIR/$peer_name-private"
    local public_key_file="$SECRETS_DIR/$peer_name-public"
    
    # Check if peer exists
    local peer_exists=false
    if [[ -d "$peer_dir" ]]; then
        peer_exists=true
    fi
    if sudo test -f "$private_key_file" 2>/dev/null; then
        peer_exists=true
    fi
    
    if [[ "$peer_exists" == false ]]; then
        error "Peer '$peer_name' does not exist"
        exit 1
    fi
    
    echo "Peer: $peer_name"
    echo "=============="
    
    if [[ -f "$peer_dir/ip.txt" ]]; then
        echo "IP: $(cat "$peer_dir/ip.txt")"
    fi
    
    if sudo test -f "$public_key_file" 2>/dev/null; then
        echo "Public Key: $(safe_read_file "$public_key_file")"
    fi
    
    if sudo test -f "$private_key_file" 2>/dev/null; then
        echo "Private Key File: $private_key_file"
    fi
    
    if [[ -f "$WG_DIR/$peer_name.conf" ]]; then
        echo "Config file: $WG_DIR/$peer_name.conf"
    fi
}

# Show QR code for peer config
show_qr() {
    local peer_name="$1"
    local config_file="$WG_DIR/$peer_name.conf"
    local quiet="${2:-false}"
    
    # Check if peer config exists
    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
        error "Use '$0 show $peer_name' to check if peer exists"
        exit 1
    fi
    
    # Check if qrencode is available
    if ! command -v qrencode >/dev/null 2>&1; then
        if [[ "$quiet" == "false" ]]; then
            error "qrencode is not installed"
            info "Install it with: sudo apt install qrencode (Debian/Ubuntu) or sudo dnf install qrencode (Fedora)"
            info "Or on NixOS, add 'qrencode' to your system packages"
            exit 1
        else
            warning "qrencode not available - skipping QR code display"
            return
        fi
    fi
    
    if [[ "$quiet" == "false" ]]; then
        info "Generating QR code for peer: $peer_name"
    fi
    echo ""
    
    # Generate QR code in terminal
    qrencode -t ansiutf8 < "$config_file"
    
    echo ""
    info "Scan this QR code with your WireGuard mobile app"
    if [[ "$quiet" == "false" ]]; then
        info "Config file location: $config_file"
    fi
}

# Clean orphaned files - FIXED: Update IP cache on clean
clean_orphaned() {
    local peer_name="$1"
    
    if [[ -z "$peer_name" ]]; then
        error "Please specify a peer name to clean"
        exit 1
    fi
    
    local peer_dir="$WG_DIR/$peer_name"
    local private_key_file="$SECRETS_DIR/$peer_name-private"
    local public_key_file="$SECRETS_DIR/$peer_name-public"
    local config_file="$WG_DIR/$peer_name.conf"
    local ip_cache_file="$WG_DIR/used-ips.txt"
    
    warning "Cleaning orphaned files for peer: $peer_name"
    
    # Remove IP from cache if directory exists
    if [[ -f "$peer_dir/ip.txt" ]]; then
        local peer_ip
        peer_ip=$(cat "$peer_dir/ip.txt")
        if [[ -f "$ip_cache_file" ]]; then
            grep -v "^$peer_ip$" "$ip_cache_file" > "$ip_cache_file.tmp" && mv "$ip_cache_file.tmp" "$ip_cache_file"
            info "Removed IP $peer_ip from cache"
        fi
    fi
    
    # Remove all possible files
    if [[ -d "$peer_dir" ]]; then
        rm -rf "$peer_dir"
        info "Removed directory: $peer_dir"
    fi
    
    if sudo test -f "$private_key_file" 2>/dev/null; then
        sudo rm -f "$private_key_file"
        info "Removed private key: $private_key_file"
    fi
    
    if sudo test -f "$public_key_file" 2>/dev/null; then
        sudo rm -f "$public_key_file"
        info "Removed public key: $public_key_file"
    fi
    
    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        info "Removed config file: $config_file"
    fi
    
    # Update peers configuration
    update_peers_file
    
    success "Cleaned orphaned files for peer '$peer_name'"
}

# Main function
main() {
    check_root
    init_dirs
    
    case "${1:-}" in
        "add")
            if [[ -z "${2:-}" ]]; then
                error "Please specify a peer name"
                echo "Usage: $0 add <peer-name> [ip-address] [server-ip]"
                exit 1
            fi
            add_peer "$2" "${3:-}" "${4:-}"
            ;;
        "remove")
            if [[ -z "${2:-}" ]]; then
                error "Please specify a peer name"
                echo "Usage: $0 remove <peer-name>"
                exit 1
            fi
            remove_peer "$2"
            ;;
        "list")
            list_peers
            ;;
        "show")
            if [[ -z "${2:-}" ]]; then
                error "Please specify a peer name"
                echo "Usage: $0 show <peer-name>"
                exit 1
            fi
            show_peer "$2"
            ;;
        "clean")
            if [[ -z "${2:-}" ]]; then
                error "Please specify a peer name to clean"
                echo "Usage: $0 clean <peer-name>"
                exit 1
            fi
            clean_orphaned "$2"
            ;;
        "endpoint")
            if [[ -f "$ENDPOINT_FILE" ]]; then
                echo "Current endpoint: $(cat "$ENDPOINT_FILE")"
                echo -n "Update endpoint? [y/N]: " >&2
                read -r response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    rm -f "$ENDPOINT_FILE"
                    get_server_endpoint ""
                fi
            else
                echo "No endpoint configured yet."
                echo "It will be set when you add your first peer."
            fi
            ;;
        "qr")
            if [[ -z "${2:-}" ]]; then
                error "Please specify a peer name"
                echo "Usage: $0 qr <peer-name>"
                exit 1
            fi
            show_qr "$2"
            ;;
        *)
            echo "WireGuard Peer Manager"
            echo "Usage: $0 {add|remove|list|show|clean|endpoint} [arguments]"
            echo ""
            echo "Commands:"
            echo "  add <name> [ip] [server-ip]  Add a new peer (IP auto-assigned if not specified)"
            echo "  remove <name>                Remove an existing peer"
            echo "  list                         List all peers"
            echo "  show <name>                  Show details for a specific peer"
            echo "  clean <name>                 Clean orphaned files for a peer"
            echo "  endpoint                     Show/update server endpoint"
            echo "  qr <name>                    Show QR code for peer config"
            echo ""
            echo "Examples:"
            echo "  $0 add alice-laptop"
            echo "  $0 add mary-phone 10.100.0.10"
            echo "  $0 add bob-tablet \"\" 192.168.1.100"
            echo "  $0 remove alice-laptop"
            echo "  $0 list"
            echo "  $0 show alice-laptop"
            echo "  $0 clean alice-laptop"
            echo "  $0 endpoint"
            echo "  $0 qr alice-laptop"
            exit 1
            ;;
    esac
}

main "$@"
