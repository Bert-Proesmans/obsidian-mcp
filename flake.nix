{
  description = "obsidian-mcp: MCP server for Obsidian vaults, built with local (fastembed/ONNX) embeddings";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # nixpkgs' prebuilt ONNX Runtime shared library. ort-sys (pulled in by
        # fastembed -> ort) is told about this via ORT_LIB_LOCATION so its
        # build.rs skips trying to download a prebuilt archive from pyke's CDN
        # (which would fail in the Nix sandbox with no network access).
        onnxruntime = pkgs.onnxruntime;

        # Pre-fetched HuggingFace Hub cache for the pre-packaged local
        # embedding model, `snowflake/snowflake-arctic-embed-s` — a built-in
        # fastembed preset (`EmbeddingModel::SnowflakeArcticEmbedS`), loaded
        # via the plain hf-hub-backed `TextEmbedding::try_new` path (no
        # `try_new_from_user_defined`/external-data detour needed: this is a
        # standard BERT-family bi-encoder with a single `onnx/model.onnx`,
        # no companion `.onnx_data` file — confirmed via the HF repo's file
        # listing).
        #
        # Casing gotcha, verified rather than assumed: fastembed's own model
        # table (`models/text_embedding.rs`) gives this variant's
        # `model_code` as lowercase `"snowflake/snowflake-arctic-embed-s"`,
        # while the *M* variant right next to it uses capitalized
        # `"Snowflake/snowflake-arctic-embed-m"` — inconsistent within
        # fastembed itself. hf-hub's cache folder name
        # (`Repo::folder_name()`) is a direct string transform of that exact
        # `model_code` ("models--" + repo_id with "/" -> "--"), so what
        # matters for our cache to be *found* is fastembed's lowercase
        # string, not HF's canonical repo casing: the HF API's
        # `/revision/main` lookup for `snowflake/snowflake-arctic-embed-s`
        # itself resolves (redirects) to the canonical `id`
        # `"Snowflake/snowflake-arctic-embed-s"`, and a plain `resolve/main`
        # file URL under the lowercase org 307-redirects to the capitalized
        # one — so the *download* URLs below use the canonical capitalized
        # form (which `fetchurl` follows via `curl -L`), but the on-disk
        # cache directory this derivation produces is deliberately lowercase
        # `models--snowflake--snowflake-arctic-embed-s` to match what
        # `hf_hub::Repo::folder_name()` actually computes from fastembed's
        # model_code at runtime.
        snowflakeArcticEmbedSModelCache =
          let
            # Resolved from https://huggingface.co/api/models/snowflake/snowflake-arctic-embed-s/revision/main
            rev = "e596f507467533e48a2e17c007f0e1dacc837b33";
            repoDir = "models--snowflake--snowflake-arctic-embed-s";
            fetch =
              name: hash:
              pkgs.fetchurl {
                url = "https://huggingface.co/Snowflake/snowflake-arctic-embed-s/resolve/${rev}/${name}";
                sha256 = hash;
              };
            files = {
              "config.json" = fetch "config.json" "4e519aa92ec40943356032afe458c8829d70c5766b109e4a57490b82f72dcfb7";
              "special_tokens_map.json" =
                fetch "special_tokens_map.json"
                  "5d5b662e421ea9fac075174bb0688ee0d9431699900b90662acd44b2a350503a";
              "tokenizer_config.json" =
                fetch "tokenizer_config.json"
                  "9ca59277519f6e3692c8685e26b94d4afca2d5438deff66483db495e48735810";
              "tokenizer.json" =
                fetch "tokenizer.json" "91f1def9b9391fdabe028cd3f3fcc4efd34e5d1f08c3bf2de513ebb5911a1854";
              "onnx/model.onnx" =
                fetch "onnx/model.onnx" "579c1f1778a0993eb0d2a1403340ffb491c769247fb46acc4f5cf8ac5b89c1e1";
            };
          in
          pkgs.runCommand "snowflake-arctic-embed-s-hf-cache" { } (
            ''
              snap="$out/${repoDir}/snapshots/${rev}"
              mkdir -p "$snap/onnx"
              mkdir -p "$out/${repoDir}/refs"
              # No trailing newline: hf-hub uses this file's raw contents
              # verbatim as the snapshot directory name.
              printf '%s' "${rev}" > "$out/${repoDir}/refs/main"
            ''
            + pkgs.lib.concatStringsSep "\n" (
              pkgs.lib.mapAttrsToList (name: src: ''ln -s ${src} "$snap/${name}"'') files
            )
          );
      in
      {
        packages.obsidian-mcp = pkgs.rustPlatform.buildRustPackage {
          pname = "obsidian-mcp";
          version = "3.1.0";

          src = ./.;

          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          nativeBuildInputs = with pkgs; [
            # Wraps the built binary to default it onto the pre-fetched
            # Snowflake Arctic Embed S model below.
            makeWrapper
          ];

          buildInputs = with pkgs; [
            onnxruntime
          ];

          buildFeatures = [ "embeddings" ];
          buildNoDefaultFeatures = false;

          # Only build the MCP server binary; obsidian-semanticd (the
          # optional shared-index daemon) is not needed for a single stdio
          # client and is skipped here.
          buildAndTestSubdir = null;
          cargoBuildFlags = [
            "--bin"
            "obsidian-mcp"
          ];

          # Tests reach into the network (model downloads) / are not needed
          # for producing the binary.
          doCheck = false;

          env = {
            ORT_LIB_LOCATION = "${onnxruntime}/lib";
            ORT_PREFER_DYNAMIC_LINK = "1";
          };

          # No autoPatchelfHook / manual RPATH fixup needed: nixpkgs' cc/ld
          # wrapper already adds a RUNPATH entry for every `-L` search path
          # emitted by build scripts (ort-sys's ORT_LIB_LOCATION), so the
          # produced binary already finds libonnxruntime at runtime. Verified
          # empirically: `readelf -d`/`ldd` on a build with no patchelf hook
          # show a correct RUNPATH and no "not found" libs, and the stdio
          # smoke test passes with `env -i` (no LD_LIBRARY_PATH).
          #
          # No openssl/pkg-config/cmake/perl/nasm either (all previously
          # needed, now gone): `fastembed` is now depended on with
          # `default-features = false` plus only `hf-hub-rustls-tls` (see
          # Cargo.toml) instead of its actual defaults
          # (`ort-download-binaries-native-tls` + `hf-hub-native-tls` +
          # `image-models`). That default set was the sole reason
          # `openssl-sys`/`native-tls`/`aws-lc-sys`-adjacent build tooling was
          # ever needed: `ort-download-binaries-native-tls` turned on
          # `ort/download-binaries` + `ort/tls-native` purely to let `ort`'s
          # own build.rs fetch a prebuilt ONNX Runtime over HTTPS via `ureq`
          # (dead code for us — `ORT_LIB_LOCATION` makes ort-sys's build.rs
          # return before that branch is ever reached) and `hf-hub-native-tls`
          # put hf-hub's HTTP client on native-tls/openssl instead of
          # rustls. Verified empirically both before and after: `cargo tree -i
          # openssl-sys`/`-i native-tls` matched zero packages, `cargo tree -e
          # features -i ort-sys` showed exactly `{ndarray, std, api-17..24}`
          # with no `download-binaries`/`tls-native`/`copy-dylibs`, and the
          # build/ldd/stdio+search_semantic smoke tests below still pass with
          # both removed from nativeBuildInputs/buildInputs.

          # Default (not force-override: `--set-default` only applies when
          # the variable is unset in the caller's environment, so a user can
          # still point at a different cache or model at runtime) the local
          # embedding model's cache dir at the pre-fetched, network-free
          # HuggingFace cache assembled above, and select that model by
          # default. This is deliberately only an env-var default set by the
          # wrapper, not a change to the compiled-in `DEFAULT_MODEL_NAME` in
          # `src/config.rs`, which is also used by the semantic-daemon flow
          # and referenced by a wide swath of unrelated tests/fixtures.
          # HF_HUB_OFFLINE=1 is set too for documentation / future-proofing,
          # but hf-hub 0.5.0 does not actually read that variable at all
          # (confirmed by grepping its source) — it's the fully-populated
          # cache path that guarantees zero network access, not this flag.
          #
          # OBSIDIAN_EMBEDDINGS_MODEL is set to the exact fastembed enum name
          # `SnowflakeArcticEmbedS`, not the repo string
          # `snowflake/snowflake-arctic-embed-s`: `resolve_local_model` in
          # `src/vault/embeddings.rs` tries an exact enum-name match first,
          # falling back to matching the configured name's repo-name suffix
          # against every model's `model_code` — and `SnowflakeArcticEmbedS`
          # and `SnowflakeArcticEmbedSQ` share the *identical* `model_code`
          # (fastembed differentiates them only by `model_file`, quantized
          # vs. not), so the repo-string form is genuinely ambiguous there
          # (verified empirically: it fails at runtime with "ambiguous local
          # embedding model"). The bare enum name matches the first,
          # unambiguous branch directly.
          postFixup = ''
            wrapProgram $out/bin/obsidian-mcp \
              --set-default FASTEMBED_CACHE_DIR "${snowflakeArcticEmbedSModelCache}" \
              --set-default OBSIDIAN_EMBEDDINGS_MODEL "SnowflakeArcticEmbedS" \
              --set-default HF_HUB_OFFLINE "1"
          '';

          meta = {
            description = "MCP server for Obsidian vaults — direct filesystem access for AI agents, built with local embeddings";
            mainProgram = "obsidian-mcp";
          };
        };

        packages.default = self.packages.${system}.obsidian-mcp;
        packages.snowflake-arctic-embed-s-model = snowflakeArcticEmbedSModelCache;

        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.obsidian-mcp ];
          packages = with pkgs; [
            cargo
            rustc
            rust-analyzer
          ];
        };
      }
    );
}
