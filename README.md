# SETUP_COMFYUI.sh

One script that installs and updates [ComfyUI](https://github.com/Comfy-Org/ComfyUI) on Linux (macOS should work but is untested). It creates a start script that updates ComfyUI and then starts it. It also points ComfyUI at your own models folder and serves your own web pages.

Messages from the scripts are in Swedish.

---

# Part 1 – How to use it

## Where to put the script

The folder that holds `SETUP_COMFYUI.sh` is called **origin**. Your models and your own pages go in origin, so ComfyUI itself can be deleted and reinstalled without losing them.

```
my-comfy/                    <- origin
├── SETUP_COMFYUI.sh
├── models/                  <- created by setup; put your models here
│   ├── checkpoints/
│   ├── loras/
│   ├── vae/
│   └── … (25 model types, see below)
├── frontend/                <- optional: your own standalone pages
│   ├── index.html
│   └── …
└── ComfyUI/                 <- default install location (can be anywhere)
```

origin is found from the script's real path, so calling the script through a symlink works too.

## Requirements

- `git`
- Python **3.10 or newer** with the `venv` module (3.13 recommended). The script tries `python3.13`, `python3.12`, `python3.11`, `python3.14`, `python3.10` and then `python3`, in that order. To force a specific one, set `COMFY_PYTHON=/path/to/python`.

**If something is missing, setup offers to install it for you** (see [Automatic prerequisite installation](#automatic-prerequisite-installation)). On Debian/Ubuntu that means `sudo apt-get install …`. You are asked first (default: yes); with `-y` it installs without asking.

## Quick start

```bash
cd my-comfy
./SETUP_COMFYUI.sh                 # asks for install folder (picker or terminal) and channel
ComfyUI/_START_COMFYUI.sh          # update + start
```

Then open <http://127.0.0.1:8188>.

### Choosing the install folder

When setup runs in a terminal with no `INSTALL_DIR` and no `-y`:

- **With a desktop** (`DISPLAY`/`WAYLAND_DISPLAY` set and `zenity` or `kdialog` installed, or macOS via `osascript`), a folder picker opens in origin. **Pick the folder that should *contain* ComfyUI**; setup creates the `ComfyUI` subfolder in it. For example, picking `~/AI` installs to `~/AI/ComfyUI`. Two exceptions, so you never get `ComfyUI/ComfyUI`: if you pick an existing ComfyUI install, or an empty folder named `ComfyUI`, that folder is used as-is. The chosen path is printed (`ComfyUI installeras i …`).
- **Cancelling the picker** doesn't abort; setup asks in the terminal instead.
- **In the terminal**, the default (`<origin>/ComfyUI`) is pre-filled and editable, and **Tab completes paths**. Press Enter to accept. `~` and relative paths work. On macOS's old bash 3.2, the default is shown in brackets instead of pre-filled.
- `--no-gui` always uses the terminal. `--gui` uses the picker even if no `DISPLAY` is detected (e.g. over SSH with X forwarding). zenity/kdialog are never installed automatically.

To run without any questions:

```bash
./SETUP_COMFYUI.sh -y                          # all defaults → ./ComfyUI, stable
./SETUP_COMFYUI.sh -y -c latest ~/ComfyUI      # own folder, latest channel
```

## Setup options

```
./SETUP_COMFYUI.sh [options] [INSTALL_DIR]
```

| Option | Meaning |
|---|---|
| `INSTALL_DIR` | Where ComfyUI goes. Default: `<origin>/ComfyUI`. Relative paths and `~` work. |
| `-c`, `--channel stable\|latest` | `stable` = newest release tag (default), `latest` = newest commit on `master`. |
| `-t`, `--torch BACKEND` | PyTorch build: `auto` (default), `cuda`, `cuda-legacy`, `rocm`, `xpu`, `cpu`, `default`, `skip`. Can also be set with the environment variable `COMFY_TORCH_BACKEND`. |
| `-y`, `--yes` | Ask nothing, use defaults. The same happens automatically when stdin is not a terminal. |
| `--gui` / `--no-gui` | Force / disable the graphical folder picker (default: used when a desktop is available). |
| `-h`, `--help` | Show help. |

Giving `INSTALL_DIR` only skips the folder question. In a terminal you are still asked for the channel unless you also pass `-c` or `-y`.

## Daily use: `_START_COMFYUI.sh`

```bash
ComfyUI/_START_COMFYUI.sh                  # update, then start
ComfyUI/_START_COMFYUI.sh --no-update      # start without updating
ComfyUI/_START_COMFYUI.sh --update-only    # update, don't start
ComfyUI/_START_COMFYUI.sh --cpu --listen   # any other args go to ComfyUI's main.py
```

- `--no-update` and `--update-only` are handled by the script. **Every other argument** is passed to ComfyUI's `main.py` (e.g. `--cpu`, `--listen`, `--port 8189`).
- Stop it with **Ctrl+C** (or `kill`). A third Ctrl+C force-kills it.

## Output: `/tmp/ComfyUI_output`

ComfyUI always starts with `--output-directory /tmp/ComfyUI_output`. **That folder is deleted when ComfyUI exits**, whether it exits normally, through Ctrl+C or through SIGTERM. Save anything you want to keep before you stop it.

## Switching stable / latest

Either re-run setup with a channel:

```bash
./SETUP_COMFYUI.sh -c latest ComfyUI
```

or edit `"channel"` in `ComfyUI/_CONFIG.json`. The next `_START_COMFYUI.sh` run then checks out the right version:

- **stable** – the highest `vX.Y.Z` tag (detached HEAD)
- **latest** – the newest commit on `master`

## Your own pages: `/e/`

Put standalone pages (HTML, JS, CSS, images …) in `origin/frontend/`. They are served live at:

```
http://127.0.0.1:8188/e/            -> redirects to /e/index.html (if it exists)
http://127.0.0.1:8188/e/sub/page.html
```

- Nothing is copied, so edits show up when you reload the page; no restart needed.
- Your `.js` files are **not** loaded into the ComfyUI interface.
- To use a different path, set `"frontend_url_path"` in `_CONFIG.json` (e.g. `"/sida"`) and restart ComfyUI.
- If `origin/frontend/` doesn't exist, nothing is served and everything else works as normal.

## Re-running setup

Setup can be run as many times as you like. If the install folder already holds ComfyUI, setup **updates and reconfigures** instead of failing:

- keeps the existing `.venv` and the PyTorch build (unless you pass a different `-t`)
- uses the current channel as the default answer
- rewrites `_START_COMFYUI.sh` and `extra_model_paths.yaml`, and updates `_CONFIG.json` while keeping any keys you added yourself
- refuses a folder that exists, isn't empty and isn't ComfyUI

Re-run it after moving the origin folder, so the paths are updated.

---

# Part 2 – How it works

## What setup does

1. Checks for `git` and a suitable Python, and offers to install whatever is missing.
2. Asks for the install folder and channel.
3. Clones ComfyUI (only on first install).
4. Creates `.venv/` and installs PyTorch, **before** `requirements.txt`, so the plain `torch` line there doesn't pull the wrong build.
5. Writes `_CONFIG.json`, `extra_model_paths.yaml` and `_START_COMFYUI.sh`.
6. Runs `_START_COMFYUI.sh --update-only` to check out the right version and install dependencies. The update logic lives only in the start script.

## Automatic prerequisite installation

If `git`, a Python ≥ 3.10 or its `venv`/`ensurepip` module is missing, setup installs it with the system package manager and then checks again:

| Package manager | git | Python | venv module |
|---|---|---|---|
| `apt-get` (Debian/Ubuntu) | `git ca-certificates` | `python3 python3-venv` | `python3.X-venv` (fallback: `python3-venv`) |
| `dnf` (Fedora/RHEL) | `git` | `python3` | `python3` |
| `pacman` (Arch) | `git` | `python` | `python` |
| `zypper` (openSUSE) | `git` | `python3` | `python3` |
| `brew` (macOS) | `git` | `python@3.13` | `python@3.13` |

- **Debian/Ubuntu:** `ensurepip` lives in the version-specific package, so setup installs only the one matching the Python it found (on Debian 13: `python3.13-venv`). If that package isn't in your repositories, it falls back to `python3-venv`. When Python itself is missing, it installs `python3 python3-venv`. `apt-get update` runs first.
- **Permissions:** as root, commands run directly. Otherwise `sudo` is used if it is installed. Without a terminal, `sudo -n` is used, so it fails instead of hanging at a password prompt. `brew` never uses sudo.
- **Confirmation:** in a terminal you get a yes/no question (default yes). With `-y`, or when stdin is not a terminal, setup installs without asking.
- **When it can't install** (no supported package manager, no root/sudo, you answer no, or the install fails), setup stops and prints the exact command to run yourself, e.g.
  `sudo apt-get update && sudo apt-get install -y python3.13-venv`.
- A Python that is too old (< 3.10) is **not** upgraded automatically. Install a newer one and point `COMFY_PYTHON` at it.

## Models: `extra_model_paths.yaml`

Setup writes `ComfyUI/extra_model_paths.yaml` with `base_path: <origin>/models` and `is_default: true`, and creates the subfolders. The folder names follow ComfyUI's `extra_model_paths.yaml.example`:

`checkpoints`, `configs`, `loras`, `vae`, `text_encoders` + `clip`, `diffusion_models` + `unet`, `clip_vision`, `style_models`, `embeddings`, `diffusers`, `vae_approx`, `controlnet` + `t2i_adapter`, `gligen`, `upscale_models`, `latent_upscale_models`, `hypernetworks`, `photomaker`, `classifiers`, `model_patches`, `audio_encoders`, `background_removal`, `frame_interpolation`, `geometry_estimation`, `optical_flow`, `detection`.

The file is rewritten on every setup run. If a hand-written version exists (one without the generated header), it is first saved as `extra_model_paths.yaml.bak`.

## `_CONFIG.json`

```json
{
  "_info": "…",
  "channel": "stable",
  "origin": "/home/you/my-comfy",
  "torch_backend": "cpu",
  "frontend_url_path": "/e"
}
```

| Key | Used for |
|---|---|
| `channel` | `stable` or `latest` – read on every start. |
| `origin` | Absolute path of origin, used to find `origin/frontend`. |
| `torch_backend` | The PyTorch build that was installed. On a re-run it is kept unless `-t` says otherwise. |
| `frontend_url_path` | URL prefix for your pages (default `/e`). Setup never overwrites it. |

The scripts read it with Python, so `jq` isn't needed.

## Serving `origin/frontend` at `/e`

ComfyUI's own web files come from the pip package `comfyui-frontend-package`, which is replaced on every update, so copying files there doesn't last. ComfyUI's normal extension mechanism (a custom node's `WEB_DIRECTORY`, served under `/extensions/<name>/`) would load **every** `.js` file into the ComfyUI page, which is wrong for standalone pages.

Instead, `_START_COMFYUI.sh` generates a tiny custom node, `custom_nodes/_origin_frontend/`. Its `__init__.py`:

- reads `origin` and `frontend_url_path` from `_CONFIG.json`
- registers a static route (`/e/…`) pointing directly at `origin/frontend`, plus `/e` and `/e/` → `index.html`
- sets **no** `WEB_DIRECTORY`, so nothing shows up in `/extensions`
- follows symlinks inside `origin/frontend`; `../` in URLs is still blocked

The node folder has a marker file, `.generated_by_setup_comfyui`. If a folder with that name exists *without* the marker, the script leaves it alone and warns.

## PyTorch backend (`-t auto`)

| Detected | Backend | Installed from |
|---|---|---|
| macOS | `default` | normal PyPI packages |
| NVIDIA (`nvidia-smi`), 20-series+ and driver ≥ 580 | `cuda` | `--extra-index-url …/whl/cu130` |
| NVIDIA, older card (compute < 7.5) or driver < 580 | `cuda-legacy` | `--extra-index-url …/whl/cu126` |
| AMD (`rocminfo`, or `/dev/kfd` + AMD GPU) | `rocm` | `--index-url …/whl/rocm7.2` |
| anything else | `cpu` | `--index-url …/whl/cpu` |

`xpu` (Intel) is never auto-detected; choose it with `-t xpu`. `skip` leaves PyTorch alone. Passing a different backend than the one installed reinstalls PyTorch with `--force-reinstall`.

## Update behaviour

On every start (unless `--no-update`):

1. **Local changes** to tracked ComfyUI files → the git update is skipped, the changed files are listed, and ComfyUI still starts. Fix with `git -C ComfyUI stash` or `git -C ComfyUI checkout -- .`.
2. `git fetch --tags`. If it fails (**offline**) → warning, and the current version starts.
3. Checks out the newest tag (`stable`) or `master` (`latest`). For `latest`, local commits on `master` that aren't on GitHub → the update is skipped with a warning.
4. `pip install -r requirements.txt` runs **only if `requirements.txt` has changed** (a hash is kept in `.venv/.requirements.sha256`).
5. Regenerates the `_origin_frontend` node.

## Generated files

```
ComfyUI/
├── _START_COMFYUI.sh            update + start (rewritten by setup)
├── _CONFIG.json                 settings (see above)
├── extra_model_paths.yaml       -> origin/models (rewritten by setup)
├── extra_model_paths.yaml.bak   only if you had your own version
├── .venv/                       Python environment
│   └── .requirements.sha256     "requirements already installed" marker
└── custom_nodes/
    └── _origin_frontend/        rewritten on every start
        ├── __init__.py
        └── .generated_by_setup_comfyui
```

`_START_COMFYUI.sh`, `_CONFIG.json` and `extra_model_paths.yaml.bak` are added to `.git/info/exclude`, so `git status` stays clean. ComfyUI's own `.gitignore` already covers `extra_model_paths.yaml`, `.venv/` and `custom_nodes/`.

---

# Caveats & troubleshooting

- **Two instances share `/tmp/ComfyUI_output`.** When one exits, it deletes the other's output. The folder is also deleted if you pass your own `--output-directory`.
- **`ComfyUI/models/` is still scanned** as well as `origin/models/`. New downloads default to `origin/models/`.
- **ComfyUI-Manager is not installed.** `--enable-manager` also needs `ComfyUI/.venv/bin/python -m pip install -r ComfyUI/manager_requirements.txt`.
- **Tested on Linux (Debian 13) with CPU PyTorch only.** The folder picker was tested with real zenity (under Xvfb); kdialog and the macOS picker are untested. NVIDIA/AMD detection and macOS are untested. Automatic installation was tested for real with `apt` on Debian 13; the `dnf`/`pacman`/`zypper`/`brew` paths are untested. If the auto-detected build is wrong, re-run with e.g. `-t cuda-legacy` or `-t cpu`.
- **Pages at `/e/`:**
  - If `origin/frontend/` is created while ComfyUI is running, or `frontend_url_path` is changed, restart ComfyUI.
  - There is no folder listing; only `index.html` is served automatically.
  - ComfyUI's server caches images for a day (use a hard reload after editing one); `.js`/`.css` are never cached.
  - With `--offline`, ComfyUI blocks external resources (CDNs) on these pages too.
  - With `--listen`, `/e/` is reachable from the network.
- **"Pythonmiljön saknas" / "_CONFIG.json saknas"** → run `SETUP_COMFYUI.sh` first.
- **Broken `.venv`** (e.g. after a system Python upgrade) → re-run setup; it recreates the venv.
