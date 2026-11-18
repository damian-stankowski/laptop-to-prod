# 1. Base images

Every node in every environment starts from the same Debian image. This step downloads that image and checks it is the one Debian published, before anything is built on it.

**Status:** done · Debian 13.7.0 netinst, amd64 and arm64 · Bash, GnuPG, curl

The image is not stored in the repo. The repo stores which image to use, in [`images/manifest.yml`](../images/manifest.yml), and the script that downloads and verifies it, [`images/download.sh`](../images/download.sh).

## Requirements

| Tool | Used for |
|---|---|
| `curl` | Downloading the image and the checksums |
| `gpg`, `gpgv` (GnuPG) | Checking Debian's signature |
| `yq` v4 | Reading the manifest |
| `sha256sum` or `shasum` | Computing the image checksum |

`yq` must be [mikefarah/yq](https://github.com/mikefarah/yq) v4. Some Linux distributions ship an unrelated Python tool with the same name. The script detects it and stops.

macOS:

```bash
brew install gnupg yq
```

Debian or Ubuntu:

```bash
sudo apt install curl gnupg
# yq: install the binary from https://github.com/mikefarah/yq/releases
```

## Try it

```bash
make image                # download and verify the image for this machine
make image ARCH=amd64     # for another architecture (amd64 or arm64)
make image-verify         # verify the local image without downloading it
make clean                # remove downloaded images and partial downloads
```

The image is saved to `images/downloads/`, which git ignores. If a valid image is already there, nothing is downloaded. An interrupted download resumes on the next run.

The script also runs on its own. See every option with:

```bash
./images/download.sh --help
```

When its output is not a terminal, the script prints only the image path to stdout, so other scripts can use it:

```bash
iso="$(./images/download.sh)"
```

## How the image is verified

The image is accepted only if four checks pass, in this order:

1. **Trusted keys.** Each key file in [`images/keys/`](../images/keys/) must contain exactly the key whose fingerprint is pinned in the manifest. A replaced or extra key fails here.
2. **Signature.** Debian publishes `SHA256SUMS`, a list of checksums, and `SHA256SUMS.sign`, its signature. `gpgv` checks the signature against a keyring that holds only the pinned keys, so no other key on the machine can make it pass.
3. **Pinned checksum.** The checksum of the image in the signed list must equal the one pinned in the manifest. This catches a mirror serving a different release than the one the repo expects.
4. **Image.** The downloaded image must match that checksum.

The image is downloaded to a `.part` file and moved into place only after the last check passes. Any `.iso` file in `images/downloads/` has passed all four.

Mirrors are tried in the order listed in the manifest. None of them needs to be trusted: a mirror can make the download fail, but it cannot make a modified image pass.

## Decisions

### The checksum is pinned in the repo, on top of the signature

The signature proves Debian published the file. It does not prove it is the release this repo expects. Pinning the checksum makes the image part of the definition: changing it is a commit, with a diff anyone can review.

The cost: every new release means updating two checksums by hand. A wrong value cannot slip through, because the script compares it with the one Debian signed.

### Bash, not Python or Go

The script runs on bash 3.2, the version macOS ships, with tools most machines already have. There is no runtime to install before step 1.

The cost: about 600 lines of bash, which are harder to test than the same logic in a general-purpose language. `make lint` runs ShellCheck and shfmt on every script to compensate in part.

## Changing the release

To move to a new Debian release, edit [`images/manifest.yml`](../images/manifest.yml):

1. Set `release.version`, and `release.codename` if it changes.
2. Replace the `sha256` of each architecture with the value for the new image. Debian publishes them in `SHA256SUMS` next to each image, for example `https://cdimage.debian.org/debian-cd/<version>/amd64/iso-cd/SHA256SUMS`.
3. Run `make image-verify ARCH=amd64` and `make image-verify ARCH=arm64`. A wrong value fails at check 3, before the image is downloaded.

Debian moves old releases from `debian-cd` to `cdimage/archive`. The manifest lists both, so a pinned version keeps downloading after a newer one is published.

### Changing the trusted keys

Debian lists its signing keys and their fingerprints at <https://www.debian.org/CD/verify>. To add one:

1. Download the public key and save it in `images/keys/`.
2. Add its fingerprint (40 uppercase hex characters, no spaces) and its file to `trusted_keys` in the manifest.
3. Run `make image-verify`.

Compare the fingerprint with Debian's page, not with the key file you downloaded.

## Configuration

Command-line options take precedence over these variables.

| Variable | Default | Description |
|---|---|---|
| `IMAGE_ARCH` | host architecture | `amd64` or `arm64` |
| `IMAGE_OUTPUT_DIR` | `images/downloads` | Where the image is saved |
| `IMAGE_MANIFEST` | `images/manifest.yml` | Manifest to read |
| `IMAGE_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` |
| `IMAGE_LOG_FORMAT` | `auto` | `pretty` in a terminal, `plain` otherwise: one timestamped line per event, for CI |
| `IMAGE_CURL_RETRIES` | `3` | Retries per mirror |
| `IMAGE_CURL_CONNECT_TIMEOUT` | `15` | Connection timeout in seconds |
| `NO_COLOR` | unset | Disables colors when set |

## Troubleshooting

The exit code says what went wrong.

| Code | Meaning | What to do |
|---|---|---|
| 1 | General error, usually an invalid manifest | Read the error. It names the field. |
| 2 | Invalid option or unsupported architecture | Run `./images/download.sh --help`. |
| 3 | Missing tool | Install it. See [Requirements](#requirements). |
| 4 | Verification failed | Do not use the image. Check the manifest. If it is correct, retry later and run with `-v` to see which mirror served the files. |
| 5 | No mirror could be reached | Check the network. The download resumes on the next run. |

`make image-verify` still downloads `SHA256SUMS` and its signature, so it needs network access. It only skips the image.

For more detail, run with `-v` or `IMAGE_LOG_LEVEL=debug`.

## Limits

- Tested on macOS with arm64. The amd64 path and Linux hosts are not tested yet.
- Only Debian's netinst installer is supported. The image still needs an installation step before it is a running node.
- `make image-verify` cannot run offline.

## Development

```bash
make lint   # ShellCheck and shfmt
make fmt    # format the scripts with shfmt
```

Keep the script compatible with bash 3.2.
