{ config, pkgs, lib, ... }:
let
  # Change this one line to switch interfaces
  externalInterface = "eth0"
  
  # WireGuard network configuration
  wgNetwork = "10.100.0.0/24";
  wgServerIP = "10.100.0.1/24";
  wgPort = 51820;
  
  # Import peer configurations from generated file
  # This file will be created/updated by the management script
  peersFile = /etc/nixos/modules/wg-peers.nix;
  peers = if builtins.pathExists peersFile 
          then import peersFile 
          else [];
in
{
  # enable NAT
  networking.nat.enable = true;
  networking.nat.externalInterface = externalInterface;
  networking.nat.internalInterfaces = [ "wg0" ];
  
  networking.firewall = {
    allowedUDPPorts = [ wgPort ];
    # Optional: Allow forwarding for better performance
    checkReversePath = false;
  };
  
  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ wgServerIP ];
      listenPort = wgPort;

      postSetup = ''
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s ${wgNetwork} -o ${externalInterface} -j MASQUERADE
        # Optional: Enable IP forwarding if not already enabled
        echo 1 > /proc/sys/net/ipv4/ip_forward
      '';

      postShutdown = ''
        ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s ${wgNetwork} -o ${externalInterface} -j MASQUERADE 2>/dev/null || true
      '';
      
      privateKeyFile = "/etc/nixos/secrets/wg-private";

      # Use dynamically imported peers
      peers = peers;
    };
  };
  
  # Ensure the secrets directory exists with proper permissions
  system.activationScripts.wireguard-setup = ''
    mkdir -p /etc/nixos/secrets/wg-clients
    chmod 700 /etc/nixos/secrets
    chmod 700 /etc/nixos/secrets/wg-clients
  '';
}
