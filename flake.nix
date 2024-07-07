{
  description = "Lean 4 Web";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv.url = "github:cachix/devenv";
    lean4.url = "github:leanprover/lean4/d984030c6a683a80313917b6fd3e77abdf497809";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.devenv.flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        let
          lib = pkgs.lib;

          nodejs = pkgs.nodejs_18;
          nodeEnv = import ./node-env.nix {
            inherit (pkgs)
              stdenv
              lib
              python2
              runCommand
              writeTextFile
              writeShellScript
              ;
            inherit pkgs nodejs;
            libtool = if pkgs.stdenv.isDarwin then pkgs.darwin.cctools else null;
          };

          nodePackages = (
            import ./node-packages.nix {
              inherit (pkgs)
                fetchurl
                nix-gitignore
                stdenv
                lib
                fetchgit
                ;
              inherit nodeEnv;
            }
          );

          nodeDependencies = nodePackages.nodeDependencies.override ({
            # Overriding the derivation produced by buildNodeDependencies
            dontNpmInstall = true;
            src = nodePackages.nodeDependencies.src.overrideAttrs (old: {
              # Overriding the mkDerivation call in that override
              src = builtins.path {
                name = old.name + "-src";
                path = nodePackages.args.src;
                filter =
                  f: _:
                  builtins.elem (builtins.baseNameOf f) [
                    "package.json"
                    "package-lock.json"
                  ];
              };
            });
          });
        in

        {
          # Per-system attributes can be defined here. The self' and inputs'
          # module parameters provide easy access to attributes of the same
          # system.
          packages.lean4web = pkgs.stdenv.mkDerivation {
            name = "lean4web-client";
            src = lib.sourceByRegex ./. [
              "^client.*$"
              "^vite\.config\.ts$"
              "^index\.html$"
              "^package\.json$"
              "^package-lock\.json$"
            ];
            buildInputs = [ nodejs ];
            buildPhase = ''
              ln -s ${nodeDependencies}/lib/node_modules ./node_modules
              export PATH="${nodeDependencies}/bin:$PATH"

              npm run build_client
              cp -r client/dist $out/
            '';
          };

          packages.nodeDependencies = nodeDependencies;

          packages.client-proxy-oci =
            let
              # Most of the following options are adapted from
              # <https://github.com/NixOS/nixpkgs/blob/nixos-24.05/nixos/modules/services/web-servers/nginx/default.nix>

              # Mime.types values are taken from brotli sample configuration - https://github.com/google/ngx_brotli
              # and Nginx Server Configs - https://github.com/h5bp/server-configs-nginx
              # "text/html" is implicitly included in {brotli,gzip,zstd}_types
              compressMimeTypes = [
                "application/atom+xml"
                "application/geo+json"
                "application/javascript" # Deprecated by IETF RFC 9239, but still widely used
                "application/json"
                "application/ld+json"
                "application/manifest+json"
                "application/rdf+xml"
                "application/vnd.ms-fontobject"
                "application/wasm"
                "application/x-rss+xml"
                "application/x-web-app-manifest+json"
                "application/xhtml+xml"
                "application/xliff+xml"
                "application/xml"
                "font/collection"
                "font/otf"
                "font/ttf"
                "image/bmp"
                "image/svg+xml"
                "image/vnd.microsoft.icon"
                "text/cache-manifest"
                "text/calendar"
                "text/css"
                "text/csv"
                "text/javascript"
                "text/markdown"
                "text/plain"
                "text/vcard"
                "text/vnd.rim.location.xloc"
                "text/vtt"
                "text/x-component"
                "text/xml"
              ];

              recommendedProxyConfig = pkgs.writeText "nginx-recommended-proxy-headers.conf" ''
                proxy_set_header        Host $host;
                proxy_set_header        X-Real-IP $remote_addr;
                proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header        X-Forwarded-Proto $scheme;
                proxy_set_header        X-Forwarded-Host $host;
                proxy_set_header        X-Forwarded-Server $host;
              '';

              commonHttpConfig = ''
                # Load mime types.
                include ${pkgs.mailcap}/etc/nginx/mime.types;
                # When recommendedOptimisation is disabled nginx fails to start because the mailmap mime.types database
                # contains 1026 entries and the default is only 1024. Setting to a higher number to remove the need to
                # overwrite it because nginx does not allow duplicated settings.
                types_hash_max_size 4096;

                default_type application/octet-stream;
              '';

              nginxConf = pkgs.writeTextDir "etc/nginx/nginx.conf" ''
                user nginx nginx;
                daemon off;
                error_log /dev/stdout info;
                pid /dev/null;
                events {}
                http {
                  sendfile on;
                  tcp_nopush on;
                  tcp_nodelay on;
                  keepalive_timeout 65;
                  gzip on;
                  gzip_static on;
                  gzip_vary on;
                  gzip_comp_level 5;
                  gzip_min_length 256;
                  gzip_proxied expired no-cache no-store private auth;
                  gzip_types ${lib.concatStringsSep " " compressMimeTypes};
                  proxy_http_version      1.1;
                  # don't let clients close the keep-alive connection to upstream. See the nginx blog for details:
                  # https://www.nginx.com/blog/avoiding-top-10-nginx-configuration-mistakes/#no-keepalives
                  proxy_set_header        "Connection" "";
                  # $connection_upgrade is used for websocket proxying
                  map $http_upgrade $connection_upgrade {
                      default upgrade;
                      '''      close;
                  }
                  include ${recommendedProxyConfig};
                  include upstreams.conf;

                  ${commonHttpConfig}
                  access_log /dev/stdout;
                  server {
                    listen 80;
                    location /websocket/ {
                      # Proxy websockets upstream
                      proxy_pass https://api;
                      proxy_set_header Upgrade $http_upgrade;
                      proxy_set_header Connection "upgrade";
                      proxy_read_timeout 86400;
                    }
                    location / {
                      root /var/lib/html;
                    }
                  }
                }
              '';

              upstreams-conf = pkgs.writeTextDir "/etc/nginx/upstreams.conf" ''
                upstream api {
                  server live.lean-lang.org:443;
                }
              '';

              root = pkgs.runCommand "root" { } ''
                mkdir -p $out
                cd $out
                mkdir -p etc
                mkdir -p var/log/nginx
                mkdir -p tmp
                chmod u+w etc
                chmod u+w var/log/nginx
                chmod u+w tmp
                echo "nginx:x:1000:1000::/:" > etc/passwd
                echo "nginx:x:1000:nginx" > etc/group
              '';

              client-html = pkgs.stdenv.mkDerivation {
                name = "client-html";
                src = self'.packages.lean4web;
                installPhase = ''
                  mkdir -p $out/var/lib/html
                  cp -r $src/. $out/var/lib/html
                '';
              };
            in
            pkgs.dockerTools.buildImage {
              name = "lean4web-client-proxy";
              tag = "latest";
              copyToRoot = [
                nginxConf
                upstreams-conf
                client-html
                root
              ];
              config = {
                Cmd = [
                  "${pkgs.nginx}/bin/nginx"
                  "-c"
                  "/etc/nginx/nginx.conf"
                ];
                ExposedPorts = {
                  "80/tcp" = { };
                };
              };
            };
          devenv.shells.default = {
            packages = with pkgs; [
              podman
              elan
              nodejs
              # inputs'.lean4.packages.lean
            ];
          };
        };
      flake = {
        # The usual flake attributes can be defined here, including system-
        # agnostic ones like nixosModule and system-enumerating ones, although
        # those are more easily expressed in perSystem.
      };
    };
}
