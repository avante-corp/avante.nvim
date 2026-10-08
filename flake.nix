{
  description = "Packages and development shells for avante.nvim";

  nixConfig = {
    extra-substituters = [ "https://avante-nvim.cachix.org" ];
    extra-trusted-public-keys = [ "avante-nvim.cachix.org-1:bxXX3jAkVDlvhLePyKfznp+rsvUpKm0onR8j0BuUKkA=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      rustLibraryNames = [
          "avante-html2md"
          "avante-repo-map"
          "avante-templates"
          "avante-tokenizers"
        ];

      forAllSystems = lib.genAttrs systems;

      ragWorkspace = uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = ./py/rag-service;
      };

      ragOverlay = ragWorkspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      ragOverrides = pkgs: final: prev: {
        "rag-service" = prev."rag-service".overrideAttrs (_old: {
          src = lib.fileset.toSource {
            root = ./py/rag-service;
            fileset = lib.fileset.unions [
              ./py/rag-service/pyproject.toml
              ./py/rag-service/README.md
              (lib.fileset.fileFilter (file: file.hasExt "py") ./py/rag-service/src)
            ];
          };
        });

        docx2txt = prev.docx2txt.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem {
            setuptools = [ ];
          };
        });

        pypika = prev.pypika.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem {
            setuptools = [ ];
          };
        });
      };

      ragPythonSets = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          python = pkgs.python314;
        in
        (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            ragOverlay
            (ragOverrides pkgs)
          ]
        )
      );
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          rustPackages = lib.genAttrs rustLibraryNames (pname: pkgs.rustPlatform.buildRustPackage {
            inherit pname;
            version = (fromTOML (builtins.readFile ./Cargo.toml)).workspace.package.version;
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./Cargo.toml
                ./Cargo.lock
                ./.cargo
                ./crates
              ];
            };

            cargoDepsName = "avante";
            cargoHash = "sha256-Mtku+MLkDdBYN5xj2x4XbyFXFZ+qTfl1eX2g9VcfpFU=";
            cargoBuildFlags = [ "--package" pname ];
            nativeBuildInputs = [ pkgs.pkg-config pkgs.perl ];
            buildInputs = [ pkgs.openssl ];
            OPENSSL_NO_VENDOR = 1;

            # The workspace tests fetch web pages and tokenizer models, which
            # are unavailable in the Nix build sandbox.
            doCheck = false;

            meta = {
              description = "${pname} rust library for avante.nvim";
              license = lib.licenses.asl20;
              platforms = systems;
            };
          });
          pythonSet = ragPythonSets.${system};
          ragService = (pythonSet.mkVirtualEnv "rag-service-env" ragWorkspace.deps.default).overrideAttrs (
              old: {
                venvIgnoreCollisions = [
                  "bin/fastapi"
                    "bin/llama-parse"

                ];
              venvSkip = [
                "bin/huggingface-cli"
                "bin/chroma"
              ];
              postInstall = (old.postInstall or "") + ''
                # This application does not need shell activation scripts.
                rm -f "$out"/bin/activate "$out"/bin/activate.* "$out"/bin/Activate.ps1
              '';
              meta = (old.meta or { }) // {
                mainProgram = "avante-rag-service";
              };
            }
          );
          megaLogging = pkgs.vimUtils.buildVimPlugin {
            pname = "mega.logging";
            version = "194ad8c";
            src = pkgs.fetchFromGitHub {
              owner = "ColinKennedy";
              repo = "mega.logging";
              rev = "194ad8c300186e73c3eb1ebeb3ede42eb219be3b";
              hash = "sha256-hV7uJyu0XszGLOvcRcDNDE9P6d8GTxBX+la1lQVxx2s=";
            };
          };
          megaCmdparse = pkgs.vimUtils.buildVimPlugin {
            pname = "mega.cmdparse";
            version = "47ea5b1";
            src = pkgs.fetchFromGitHub {
              owner = "ColinKennedy";
              repo = "mega.cmdparse";
              rev = "47ea5b1b23059fbb79a8e262002f32e7cd8aed90";
              hash = "sha256-RgRsHt1O6UQ/90JeAkHvdpgfjF+I25zg/oGV0cK7t6U=";
            };
            dependencies = [ megaLogging ];
          };
          avantePlugin = pkgs.vimPlugins.avante-nvim.overrideAttrs (final: old: {
            version = self.rev or self.dirtyRev or "unknown";
            name = "vimplugin-${final.pname}-${final.version}";
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [ ./lua ./plugin ./doc ./autoload ./ftplugin ./contrib];
            };
            dependencies = old.dependencies ++ [ megaCmdparse ];
            # Native modules are built separately by the Rust packages above.
            # this overrides the nixpkgs postInstall step. Ideally we should be able to reuse nixpkgs code by
            # just overriding the avante-nvim-lib
            postInstall = lib.concatMapStringsSep "\n" (name:
              let moduleName = lib.replaceStrings [ "-" ] [ "_" ] name;
              in ''
                ln -s ${rustPackages.${name}}/lib/lib${moduleName}${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} \
                  "$out/lua/${moduleName}.so"

                install -D contrib/avante $out/bin/avante
              ''
            ) rustLibraryNames;
            doCheck = false;
          });
          avanteNeovim = pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
            plugins = [ avantePlugin pkgs.vimPlugins.fzf-lua ];

            luaRcContent = builtins. readFile ./contrib/init.lua;
          };
        in
        rustPackages // {
          inherit ragService;
          avante-nvim = avantePlugin;
          default = ragService;
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          dockerImage = pkgs.dockerTools.buildLayeredImage {
            name = "avante-nvim";
            tag = "latest";
            contents = [
              avanteNeovim
              avantePlugin # just to put "avante" in path ?
              ragService
              pkgs.bashInteractive
              pkgs.pkgsStatic.coreutils-full # inspect needs "timeout" executable
              pkgs.pkgsStatic.curl
              pkgs.git # fails in static
              pkgs.procps
              pkgs.ripgrep
              pkgs.cacert
              pkgs.dockerTools.fakeNss
            ];
            extraCommands = ''
              mkdir -p root workspace tmp
              chmod 1777 tmp
            '';
            config = {
              Cmd = [ "${lib.getExe pkgs.bashInteractive}" ];
              WorkingDir = "/workspace";
              Env = [
                "HOME=/root"
                "PATH=/bin"
                "TERM=xterm-256color"
                "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              ];
            };
          };
        }
      );

      apps = forAllSystems (system: {
        rag-service = {
          type = "app";
          program = lib.getExe self.packages.${system}.ragService;
        };
        default = self.apps.${system}.rag-service;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          mylua = pkgs.lua5_1.withPackages (lp: [
            lp.luassert

            # not needed (yet), hopefully
            lp.busted
            lp.luarocks
            lp.nlua
          ]);

          basic = pkgs.mkShell {
            name = "avante";

            packages = with pkgs; [
              rustfmt
              lua5_1.pkgs.luacheck
              lua-language-server
              ripgrep
              python314
              silver-searcher # for tests
              docker
              stylua
              mylua
              vimcats  # to generate docs
              perl # needed for cargo check
              pre-commit
            ];

            shellHook = ''
              echo "Welcome to the avante development environment!"
              export DEPS_PATH="target/tests/deps"
            '';
          };

        in
        {
          default = basic.overrideAttrs(oa: {
            buildInputs = with pkgs; [
              cargo
              rustc
              ratchet # to upgrade github actions
              pkgs.pyright # to be able to run pre-commit tests
              pkgs.ruff # to be able to run pre-commit tests
              pkgs.gcc # to build python deps
            ];
          });

          ci = let
            neovimTested = pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
              plugins = [
                pkgs.vimPlugins.plenary-nvim
              ];
            };
          in
            basic.overrideAttrs(oa: {
            buildInputs = oa.buildInputs ++ [
              neovimTested
            ];
            shellHook = oa.shellHook + ''
              export VIMRUNTIME=${pkgs.neovim-unwrapped}/share/nvim/runtime
              ${lib.concatMapStringsSep "\n" (name:
                let
                  moduleName = lib.replaceStrings [ "-" ] [ "_" ] name;
                in
                ''ln -sfv "${self.packages.${system}.${name}}/lib/lib${moduleName}${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}" "lua/${moduleName}.so"''
              ) rustLibraryNames}
              '';
          });
        }
      );
    };
}
