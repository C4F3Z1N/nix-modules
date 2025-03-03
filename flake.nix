{
  description = "Collection of custom-made modules for NixOS";

  outputs = _: {
    nixosModules = {
      host-gpg-agent = ./nixos/services/host-gpg-agent.nix;
      nebula = ./nixos/services/nebula.nix;
      remote-builder = ./nixos/nix/remote-builder.nix;
      rush = ./nixos/programs/rush.nix;
    };
  };
}
