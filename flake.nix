{
  description = "Development shell for avante.nvim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?rev=62e3050a29278c985725a86704faa1e99236b51a";
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

        chroma-hnswlib = prev.chroma-hnswlib.overrideAttrs (old: {
          nativeBuildInputs =
            (old.nativeBuildInputs or [ ])
            ++ [ final.numpy ]
            ++ final.resolveBuildSystem {
              setuptools = [ ];
            };
          preBuild = ''
            export PYTHONPATH="${pkgs.python313Packages.pybind11}/${pkgs.python313.sitePackages}:$PYTHONPATH"
          '' + (old.preBuild or "");
        });
      };

      ragPythonSets = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          # TODO update
          python = pkgs.python313;
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
        in
        {
          inherit ragService;
          default = ragService;
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
              python313
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
              '';
          });
        }
      );
    };
}
