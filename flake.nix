{
  description = "LiteLLM 1.106.2 community OCI gateway image built with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix/ddc400a6883b042646d0940e65971bb7f7e96107";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix/0fdaa03ea3c3c16dbb1fe4d69108f07227a4b42d";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs/a17819c85163988e063806ffc4f6d2716bc8ead8";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };

    litellm-src = {
      url = "github:BerriAI/litellm/49943cd52ea46aacf8db2e5cb2b890d580fe9bb4";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      litellm-src,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
      version = "1.106.2";
      revision = "49943cd52ea46aacf8db2e5cb2b890d580fe9bb4";
      # Match Prisma Client Python's generator check to Nixpkgs Prisma 6.19.3.
      prismaEngineVersion = "c2990dca591cba766e3b7ef5d9e8a84796e47ab7";
      communityExtras = [
        "proxy"
        "proxy-runtime"
        "extra-proxy"
        "semantic-router"
        "saml"
        "bedrock-realtime"
      ];

      removeNamed = name: dependencies:
        lib.filter (dependency: dependency.name != name) dependencies;
      removeAdminMcpDependency = dependency:
        if builtins.isAttrs dependency then
          !(dependency ? "include-group" && dependency."include-group" == "admin-mcp")
          && !(dependency ? name && dependency.name == "litellm-admin-mcp")
        else
          !(lib.hasPrefix "litellm-admin-mcp" (lib.toLower dependency));

      upstreamPyproject = lib.importTOML (litellm-src + "/pyproject.toml");
      uv = upstreamPyproject.tool.uv;
      pyproject = upstreamPyproject // {
        project = upstreamPyproject.project // {
          optional-dependencies =
            upstreamPyproject.project.optional-dependencies
            // {
              proxy = lib.filter
                (dependency: !(lib.hasPrefix "litellm-enterprise" (lib.toLower dependency)))
                upstreamPyproject.project.optional-dependencies.proxy;
            };
        };

        "dependency-groups" =
          builtins.removeAttrs upstreamPyproject."dependency-groups" [ "admin-mcp" ]
          // {
            proxy-dev = lib.filter
              removeAdminMcpDependency
              (upstreamPyproject."dependency-groups"."proxy-dev" or [ ]);
          };

        tool = upstreamPyproject.tool // {
          uv = uv // {
            workspace = uv.workspace // {
              members = lib.filter (member: member != "enterprise") uv.workspace.members;
            };
            sources = builtins.removeAttrs uv.sources [ "litellm-enterprise" ];
            extra-build-dependencies =
              (uv.extra-build-dependencies or { })
              // {
                "ml-dtypes" = [ "setuptools" "numpy" ];
              };
          };
        };
      };

      upstreamLock = lib.importTOML (litellm-src + "/uv.lock");
      communityLock = upstreamLock // {
        manifest = upstreamLock.manifest // {
          members = lib.filter (member: member != "litellm-enterprise") upstreamLock.manifest.members;
        };
        package = map
          (package:
            if package.name != "litellm" then
              package
            else
              package // {
                optional-dependencies = package.optional-dependencies // {
                  proxy = removeNamed "litellm-enterprise" package.optional-dependencies.proxy;
                };
                dev-dependencies =
                  builtins.removeAttrs package.dev-dependencies [ "admin-mcp" ]
                  // {
                    proxy-dev = removeNamed
                      "litellm-admin-mcp"
                      package.dev-dependencies.proxy-dev;
                  };
                metadata = package.metadata // {
                  "requires-dist" = removeNamed
                    "litellm-enterprise"
                    package.metadata."requires-dist";
                  "requires-dev" =
                    builtins.removeAttrs package.metadata."requires-dev" [ "admin-mcp" ]
                    // {
                      "proxy-dev" = removeNamed
                        "litellm-admin-mcp"
                        package.metadata."requires-dev"."proxy-dev";
                    };
                };
              })
          (lib.filter
            (package: package.name != "litellm-enterprise" && package.name != "litellm-admin-mcp")
            upstreamLock.package);
      };

      communityPackageNames = map (package: package.name) communityLock.package;
      workspace = uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = litellm-src;
        inherit pyproject;
        uvLock = communityLock;
      };
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
        dependencies = { litellm = communityExtras; };
      };

      cargoOverlay = final: prev: {
        litellm = prev.litellm.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
            pkgs.rustPlatform.cargoSetupHook
            pkgs.rustPlatform.maturinBuildHook
          ];
          cargoRoot = "litellm-rust";
          cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
            pname = "litellm";
            inherit version;
            src = litellm-src;
            cargoRoot = "litellm-rust";
            hash = "sha256-jOR+k7iKF+/TTx2qc7vLBvIoew+bPY8c/tXeFGBywgM=";
          };
          postPatch = (old.postPatch or "") + ''
            substituteInPlace pyproject.toml \
              --replace-fail '    "litellm-enterprise==0.1.76.post1",' ""
          '';
        });
      };

      pythonBase = pkgs.callPackage pyproject-nix.build.packages {
        python = pkgs.python313;
      };
      proxyExtrasOverlay = final: prev: {
        "litellm-proxy-extras" = prev."litellm-proxy-extras".overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            # Prevent stale upstream wheels from overriding the freshly built package.
            rm -rf dist
          '';
        });
      };
      pythonSet = pythonBase.overrideScope (lib.composeManyExtensions [
        pyproject-build-systems.overlays.wheel
        overlay
        cargoOverlay
        proxyExtrasOverlay
      ]);
      pythonEnv = pythonSet.mkVirtualEnv "litellm-community-${version}" {
        litellm = communityExtras;
      };

      pgbouncer = pkgs.pgbouncer.overrideAttrs (_: {
        name = "pgbouncer-1.26.0";
        version = "1.26.0";
        src = pkgs.fetchurl {
          url = "https://www.pgbouncer.org/downloads/files/1.26.0/pgbouncer-1.26.0.tar.gz";
          hash = "sha256-r9Jd1h7md103tAYpuHzghzaz5pVfMFe7IS5BD78hxx0=";
        };
      });

      prisma = pkgs.prisma_6;
      prismaEngines = pkgs.prisma-engines_6;
      # Prisma 0.11 expects tagged row dicts; Prisma 6 emits columns/types/rows.
      prismaRawQueryDecoder = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/RobertCraigie/prisma-client-py/v0.15.0/src/prisma/_raw_query.py";
        hash = "sha256-uc5uMTwqV/bBmuNLvutHeKhPzmCtcEnAYOauFczl8nU=";
      };
      prismaClient = pkgs.runCommand "litellm-prisma-client-${version}" {
        nativeBuildInputs = [ pythonEnv prisma pkgs.openssl ];
      } ''
        sitePackages="${pythonEnv}/lib/python3.13/site-packages"
        generatedPackages="$out/lib/python3.13/site-packages"
        mkdir -p "$generatedPackages/prisma"
        cp -R "$sitePackages/prisma/." "$generatedPackages/prisma/"
        chmod -R u+w "$generatedPackages/prisma"

        cp ${litellm-src}/schema.prisma "$out/schema.prisma"
        sed -i \
          -e '/^generator client {/a\  output = "'"$generatedPackages"'/prisma"' \
          -e 's/^  binaryTargets =.*/  binaryTargets = ["native"]/' \
          "$out/schema.prisma"

        export PATH="${pkgs.openssl}/bin:${prisma}/bin:${pythonEnv}/bin:$PATH"
        export PYTHONPATH="$generatedPackages:$sitePackages"
        export PRISMA_CLI_PATH="${prisma}/bin/prisma"
        export PRISMA_VERSION="${prisma.version}"
        export PRISMA_EXPECTED_ENGINE_VERSION="${prismaEngineVersion}"
        export PRISMA_SCHEMA_ENGINE_BINARY="${prismaEngines}/bin/schema-engine"
        export PRISMA_QUERY_ENGINE_BINARY="${prismaEngines}/bin/query-engine"
        export PRISMA_QUERY_ENGINE_LIBRARY="${prismaEngines}/lib/libquery_engine.node"

        prisma generate --schema="$out/schema.prisma"
        cp ${prismaRawQueryDecoder} "$generatedPackages/prisma/_raw_query.py"
        test -s "$generatedPackages/prisma/models.py"
        python -c 'from prisma.models import LiteLLM_VerificationToken'
      '';

      image = pkgs.dockerTools.buildLayeredImage {
        name = "litellm";
        tag = "${version}-community-r4";
        contents = [
          pythonEnv
          prismaClient
          prisma
          pgbouncer
          pkgs.coreutils
          pkgs.openssl
          pkgs.libsndfile.out
          pkgs.dockerTools.fakeNss
          pkgs.cacert
        ];

        config = {
          User = "10001:10001";
          WorkingDir = "/data";
          Entrypoint = [ "${pythonEnv}/bin/litellm" ];
          Cmd = [
            "--config" "/etc/litellm/config.yaml"
            "--host" "0.0.0.0"
            "--port" "4000"
          ];
          Env = [
            "HOME=/data"
            "TMPDIR=/tmp"
            "XDG_CACHE_HOME=/data/.cache"
            "PYTHONPATH=${prismaClient}/lib/python3.13/site-packages:${pythonEnv}/lib/python3.13/site-packages"
            "PATH=${pkgs.coreutils}/bin:${pkgs.openssl}/bin:${prisma}/bin:${pgbouncer}/bin:${pythonEnv}/bin"
            "PYTHONUNBUFFERED=1"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "LD_LIBRARY_PATH=${pkgs.libsndfile.out}/lib"
            "PRISMA_OFFLINE_MODE=true"
            "PRISMA_CLI_PATH=${prisma}/bin/prisma"
            "PRISMA_VERSION=${prisma.version}"
            "PRISMA_EXPECTED_ENGINE_VERSION=${prismaEngineVersion}"
            "PRISMA_BINARY_CACHE_DIR=/data/.cache/prisma/binaries"
            "PRISMA_NODEENV_CACHE_DIR=/data/.cache/prisma/nodeenv"
            "PRISMA_SCHEMA_ENGINE_BINARY=${prismaEngines}/bin/schema-engine"
            "PRISMA_QUERY_ENGINE_BINARY=${prismaEngines}/bin/query-engine"
            "PRISMA_QUERY_ENGINE_LIBRARY=${prismaEngines}/lib/libquery_engine.node"
          ];
          ExposedPorts = { "4000/tcp" = { }; };
          Healthcheck = {
            Test = [
              "CMD"
              "${pythonEnv}/bin/python"
              "-c"
              "import urllib.request; urllib.request.urlopen('http://127.0.0.1:4000/health/liveliness', timeout=2)"
            ];
            Interval = 30 * 1000000000;
            Timeout = 5 * 1000000000;
            StartPeriod = 30 * 1000000000;
            Retries = 3;
          };
          Volumes = { "/data" = { }; };
          Labels = {
            "org.opencontainers.image.source" = "https://github.com/BerriAI/litellm";
            "org.opencontainers.image.version" = version;
            "org.opencontainers.image.revision" = revision;
            "org.opencontainers.image.licenses" = "MIT";
            "org.opencontainers.image.description" =
              "LiteLLM community gateway; excludes Enterprise and Admin Agent packages";
            "com.rogernavelsaker.litellm.edition" = "community";
          };
        };

        fakeRootCommands = ''
          mkdir -p ./etc/litellm ./data ./tmp
          # Prisma Client Python probes os-release before honoring PRISMA_QUERY_ENGINE_BINARY.
          printf 'NAME="LiteLLM community OCI image"\nID=litellm\n' > ./etc/os-release
          install -m 0644 ./etc/passwd ./etc/passwd.tmp
          mv -f ./etc/passwd.tmp ./etc/passwd
          install -m 0644 ./etc/group ./etc/group.tmp
          mv -f ./etc/group.tmp ./etc/group
          grep -q '^litellm:x:10001:' ./etc/passwd || \
            echo 'litellm:x:10001:10001:LiteLLM:/data:/nonexistent' >> ./etc/passwd
          grep -q '^litellm:x:10001:' ./etc/group || \
            echo 'litellm:x:10001:' >> ./etc/group
          chown -R 10001:10001 ./data
          chmod 0700 ./data
          chmod 1777 ./tmp
        '';
      };

      imageCheck = pkgs.runCommand "litellm-image-build-check" { } ''
        test -s ${image}
        touch "$out"
      '';

      communityCheck = pkgs.runCommand "litellm-community-runtime-check" {
        nativeBuildInputs = [ pythonEnv pgbouncer prisma pkgs.openssl pkgs.libsndfile.out ];
      } ''
        export HOME="$TMPDIR/home"
        export XDG_CACHE_HOME="$HOME/.cache"
        export LITELLM_MASTER_KEY="sk-test-only-00000000000000000000000000000000"
        export LITELLM_SALT_KEY="community-check-only-not-a-secret-0000000000"
        export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        export LD_LIBRARY_PATH="${pkgs.libsndfile.out}/lib"
        export LITELLM_LOCAL_MODEL_COST_MAP=true
        mkdir -p "$HOME" "$XDG_CACHE_HOME"
        export PATH="${pkgs.openssl}/bin:${prisma}/bin:${pgbouncer}/bin:${pythonEnv}/bin:$PATH"
        export PYTHONPATH="${prismaClient}/lib/python3.13/site-packages:${pythonEnv}/lib/python3.13/site-packages"

        pgbouncer --version
        prisma --version

        python - <<'PY'
        import importlib.metadata

        names = {
            distribution.metadata["Name"].lower().replace("_", "-")
            for distribution in importlib.metadata.distributions()
            if distribution.metadata.get("Name")
        }
        assert "litellm" in names
        assert "litellm-proxy-extras" in names
        assert "litellm-enterprise" not in names
        assert "litellm-admin-mcp" not in names

        from prisma import models
        from prisma._raw_query import deserialize_raw_results

        assert hasattr(models, "LiteLLM_VerificationToken")
        assert deserialize_raw_results({
            "columns": ["?column?", "big", "ids"],
            "types": ["int", "bigint", "bigint-array"],
            "rows": [[1, "9007199254740993", ["4", "5"]]],
        }) == [{"?column?": 1, "big": 9007199254740993, "ids": [4, 5]}]
        from litellm_proxy_extras import prisma_toolchain
        assert callable(prisma_toolchain.run_prisma)

        assert importlib.metadata.version("litellm") == "1.106.2"
        import litellm
        PY

        cat > "$TMPDIR/config.yaml" <<'YAML'
        model_list: []
        YAML

        python - "$TMPDIR/config.yaml" "$TMPDIR/litellm.log" <<'PY'
        import pathlib
        import subprocess
        import sys
        import time
        import urllib.error
        import urllib.request

        log_path = pathlib.Path(sys.argv[2])
        log = log_path.open("w")
        process = subprocess.Popen(
            [
                "${pythonEnv}/bin/litellm",
                "--config",
                sys.argv[1],
                "--host",
                "127.0.0.1",
                "--port",
                "4000",
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            for _ in range(60):
                if process.poll() is not None:
                    log.flush()
                    raise RuntimeError(f"LiteLLM exited early; log:\\n{log_path.read_text()[-12000:]}")
                try:
                    with urllib.request.urlopen(
                        "http://127.0.0.1:4000/health/liveliness", timeout=1
                    ) as response:
                        assert response.status == 200
                    with urllib.request.urlopen(
                        "http://127.0.0.1:4000/ui/", timeout=2
                    ) as response:
                        assert response.status == 200
                        assert b"LiteLLM" in response.read(8192)
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(0.5)
            else:
                log.flush()
                raise RuntimeError(f"LiteLLM did not become healthy; log:\\n{log_path.read_text()[-12000:]}")
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.close()
        PY

        touch "$out"
      '';
    in
    assert !(builtins.elem "litellm-enterprise" communityPackageNames);
    assert !(builtins.elem "litellm-admin-mcp" communityPackageNames);
    {
      packages.${system} = {
        inherit image;
        default = image;
      };

      checks.${system} = {
        image = imageCheck;
        community = communityCheck;
      };
    };
}
