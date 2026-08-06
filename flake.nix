{
  description = "kaiba Swift development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      git-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        runtimePackages =
          with pkgs;
          [
            gh
            git
            go-task
            swiftlint
          ]
          ++ lib.optionals pkgs.stdenv.isLinux [
            swift
          ];

        devOnlyPackages = with pkgs; [
          gitleaks
        ];

        preCommitCheck = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            gitleaks = {
              enable = true;
              name = "gitleaks";
              entry = "${pkgs.lib.getExe pkgs.gitleaks} git --pre-commit --redact --staged --verbose";
              language = "system";
              pass_filenames = false;
            };
          };
        };

        devPackages = runtimePackages ++ devOnlyPackages ++ preCommitCheck.enabledPackages;
      in
      {
        packages.dev-tools = pkgs.buildEnv {
          name = "kaiba-dev-tools";
          paths = devPackages;
          pathsToLink = [ "/bin" ];
        };

        checks.pre-commit-check = preCommitCheck;

        # On Darwin, use mkShellNoCC so Nix apple-sdk setup hooks stay out of
        # the shell. Swift builds use the selected Xcode toolchain; a Nix
        # DEVELOPER_DIR/SDKROOT pointing at the pinned apple-sdk is years behind
        # the Xcode Swift compiler and breaks `swift build`.
        devShells.default = (if pkgs.stdenv.isDarwin then pkgs.mkShellNoCC else pkgs.mkShell) {
          packages = devPackages;

          shellHook = ''
            ${preCommitCheck.shellHook}
            ${lib.optionalString pkgs.stdenv.isDarwin ''
              unset SDKROOT
              if [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]; then
                export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
              else
                unset DEVELOPER_DIR
              fi
            ''}

            echo "kaiba Swift development environment ready"
            echo "Swift version: $(swift --version 2>/dev/null | head -n 1 || echo 'not available')"
            echo "Task version: $(task --version 2>/dev/null || echo 'not available')"
            echo "SwiftLint version: $(swiftlint version 2>/dev/null || echo 'not available')"
            echo "Gitleaks version: $(gitleaks version 2>/dev/null || echo 'not available')"
          '';
        };
      }
    );
}
