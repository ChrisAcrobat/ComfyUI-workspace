#!/usr/bin/env bash
# =============================================================================
#  SETUP_COMFYUI.sh – installerar och uppdaterar ComfyUI
# =============================================================================
#
#  Användning:
#    ./SETUP_COMFYUI.sh [flaggor] [INSTALLATIONSKATALOG]
#
#  Flaggor:
#    -c, --channel stable|latest   stable = senaste release-tagg (standard)
#                                  latest = senaste commit på master
#    -t, --torch BACKEND           auto (standard), cuda, cuda-legacy, rocm,
#                                  xpu, cpu, default, skip
#    -y, --yes                     fråga ingenting, använd standardvärden
#    -h, --help                    visa hjälp
#
#  Saknas git, Python >= 3.10 eller venv erbjuder skriptet att installera dem
#  (apt, dnf, pacman, zypper eller brew; sudo används vid behov).
#
#  "origin" = katalogen där detta skript ligger. Där förväntas:
#    origin/models/    – modeller (skapas av skriptet)
#    origin/frontend/  – egna fristående sidor (valfri), serveras live på /e/
#
#  Skriptet går att köra om hur många gånger som helst: finns ComfyUI redan i
#  installationskatalogen uppdateras/konfigureras den om i stället.
#
#  Genererade filer i installationskatalogen:
#    _START_COMFYUI.sh        – uppdaterar och startar ComfyUI
#    _CONFIG.json             – kanal (stable/latest), origin m.m.
#    extra_model_paths.yaml   – pekar ComfyUI mot origin/models
#    .venv/                   – Pythonmiljö för ComfyUI
# =============================================================================

set -euo pipefail

readonly COMFYUI_REPO_URL="${COMFYUI_REPO_URL:-https://github.com/Comfy-Org/ComfyUI.git}"
readonly MIN_PYTHON_MAJOR=3
readonly MIN_PYTHON_MINOR=10    # se requires-python i ComfyUI:s pyproject.toml
readonly START_SCRIPT_NAME="_START_COMFYUI.sh"
readonly CONFIG_NAME="_CONFIG.json"
readonly GENERATED_MARKER="# Genererad av SETUP_COMFYUI.sh"

# Undermappar som skapas i origin/models och registreras i
# extra_model_paths.yaml. Format: "nyckel:mapp[,mapp...]".
# Hämtat från ComfyUI:s extra_model_paths.yaml.example / folder_paths.py.
readonly MODEL_FOLDERS=(
  "checkpoints:checkpoints"
  "configs:configs"
  "loras:loras"
  "vae:vae"
  "text_encoders:text_encoders,clip"
  "diffusion_models:diffusion_models,unet"
  "clip_vision:clip_vision"
  "style_models:style_models"
  "embeddings:embeddings"
  "diffusers:diffusers"
  "vae_approx:vae_approx"
  "controlnet:controlnet,t2i_adapter"
  "gligen:gligen"
  "upscale_models:upscale_models"
  "latent_upscale_models:latent_upscale_models"
  "hypernetworks:hypernetworks"
  "photomaker:photomaker"
  "classifiers:classifiers"
  "model_patches:model_patches"
  "audio_encoders:audio_encoders"
  "background_removal:background_removal"
  "frame_interpolation:frame_interpolation"
  "geometry_estimation:geometry_estimation"
  "optical_flow:optical_flow"
  "detection:detection"
)

# ----------------------------------------------------------------------------
#  Hjälpfunktioner för utskrift
# ----------------------------------------------------------------------------
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mVARNING:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mFEL:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  # Skriv ut kommentarshuvudet ovan som hjälptext
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

# Symlänksäker motsvarighet till "realpath" (fungerar även på äldre macOS)
resolve_path() {
  local target=$1 dir
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target"
    return
  fi
  while [ -L "$target" ]; do
    dir=$(cd -P "$(dirname "$target")" && pwd)
    target=$(readlink "$target")
    case $target in /*) ;; *) target="$dir/$target" ;; esac
  done
  dir=$(cd -P "$(dirname "$target")" && pwd)
  printf '%s/%s\n' "$dir" "$(basename "$target")"
}

# Fråga användaren; returnerar standardvärdet i icke-interaktivt läge
ask() {
  local prompt=$1 default=$2 answer
  if [ "$INTERACTIVE" != true ]; then
    printf '%s\n' "$default"
    return
  fi
  read -r -p "$prompt [$default]: " answer </dev/tty || true
  printf '%s\n' "${answer:-$default}"
}

# ----------------------------------------------------------------------------
#  Argument
# ----------------------------------------------------------------------------
ORIGIN=$(dirname "$(resolve_path "${BASH_SOURCE[0]}")")
INSTALL_DIR=""
CHANNEL=""
TORCH_BACKEND="${COMFY_TORCH_BACKEND:-}"
INTERACTIVE=true
[ -t 0 ] || INTERACTIVE=false

while [ $# -gt 0 ]; do
  case $1 in
    -c|--channel)   [ $# -ge 2 ] || die "$1 kräver ett värde"; CHANNEL=$2; shift 2 ;;
    --channel=*)    CHANNEL=${1#*=}; shift ;;
    -t|--torch)     [ $# -ge 2 ] || die "$1 kräver ett värde"; TORCH_BACKEND=$2; shift 2 ;;
    --torch=*)      TORCH_BACKEND=${1#*=}; shift ;;
    -y|--yes)       INTERACTIVE=false; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "Okänd flagga: $1 (se --help)" ;;
    *)              [ -z "$INSTALL_DIR" ] || die "Endast en installationskatalog kan anges"
                    INSTALL_DIR=$1; shift ;;
  esac
done

# ----------------------------------------------------------------------------
#  Automatisk installation av förkrav (apt, dnf, pacman, zypper, brew)
# ----------------------------------------------------------------------------
PKG_MANAGER=""
ROOT_PREFIX=()

detect_pkg_manager() {
  if [ "$(uname -s)" = Darwin ]; then
    if command -v brew >/dev/null 2>&1; then PKG_MANAGER=brew; fi
    return 0
  fi
  local pm
  for pm in apt-get dnf pacman zypper; do
    if command -v "$pm" >/dev/null 2>&1; then
      PKG_MANAGER=$pm
      return 0
    fi
  done
}

# Paketnamn för ett förkrav: git | python | venv (venv tar Pythonversion, t.ex. 3.13)
packages_for() {
  local need=$1 version=${2:-}
  case $PKG_MANAGER:$need in
    apt-get:git)    echo "git ca-certificates" ;;
    apt-get:python) echo "python3 python3-venv" ;;
    # Debian/Ubuntu: ensurepip ligger i det versionsspecifika paketet
    # (t.ex. python3.13-venv). Saknas det i apt används python3-venv.
    apt-get:venv)   if [ -n "$version" ]; then echo "python$version-venv"; else echo python3-venv; fi ;;
    *:git)          echo git ;;
    dnf:*|zypper:*) echo python3 ;;
    pacman:*)       echo python ;;
    brew:*)         echo python@3.13 ;;
  esac
}

# Sätter ROOT_PREFIX (tom om root/brew, annars sudo). Misslyckas utan sudo.
root_prefix() {
  ROOT_PREFIX=()
  if [ "$PKG_MANAGER" = brew ] || [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  if [ -t 0 ]; then
    ROOT_PREFIX=(sudo)
  else
    ROOT_PREFIX=(sudo -n)   # ingen terminal: fråga inte efter lösenord, misslyckas direkt
  fi
}

as_root() { ${ROOT_PREFIX[@]+"${ROOT_PREFIX[@]}"} "$@"; }

# Kommandot som användaren kan köra själv (visas i frågor och felmeddelanden)
manual_install_command() {
  local p=""
  if [ "$PKG_MANAGER" != brew ] && [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    p="sudo "
  fi
  case $PKG_MANAGER in
    apt-get) echo "${p}apt-get update && ${p}apt-get install -y $*" ;;
    dnf)     echo "${p}dnf install -y $*" ;;
    pacman)  echo "${p}pacman -S --needed $*" ;;
    zypper)  echo "${p}zypper install $*" ;;
    brew)    echo "brew install $*" ;;
  esac
}

run_pkg_install() {
  case $PKG_MANAGER in
    apt-get)
      as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
      # Paket som saknas i paketkällorna: python3.X-venv ersätts med
      # python3-venv, övriga hoppas över
      local pkg available=()
      for pkg in "$@"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
          available+=("$pkg")
        elif [[ $pkg == python3.*-venv ]] && apt-cache show python3-venv >/dev/null 2>&1; then
          warn "Paketet $pkg finns inte i paketkällorna – använder python3-venv i stället."
          available+=(python3-venv)
        else
          warn "Paketet $pkg finns inte i paketkällorna – hoppar över det."
        fi
      done
      [ ${#available[@]} -gt 0 ] || return 1
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${available[@]}" ;;
    dnf)    as_root dnf install -y "$@" ;;
    pacman) as_root pacman -S --needed --noconfirm "$@" ;;
    zypper) as_root zypper --non-interactive install "$@" ;;
    brew)   brew install "$@" ;;
    *)      return 1 ;;
  esac
}

# Fråga ja/nej (standard ja); i icke-interaktivt läge alltid ja
confirm() {
  local answer
  [ "$INTERACTIVE" = true ] || return 0
  read -r -p "$1 [J/n]: " answer </dev/tty || true
  case $answer in
    ""|[JjYy]|[Jj][Aa]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ensure_packages BESKRIVNING BEHOV [PYTHONVERSION] – erbjud installation, annars avbryt
ensure_packages() {
  local what=$1 need=$2 version=${3:-} cmd
  local -a pkgs
  if [ -z "$PKG_MANAGER" ]; then
    if [ "$(uname -s)" = Darwin ]; then
      die "$what saknas. Installera Homebrew (https://brew.sh) och kör skriptet igen – eller installera själv (git: 'xcode-select --install', Python: https://www.python.org/downloads/)."
    fi
    die "$what saknas och ingen pakethanterare som stöds hittades (apt, dnf, pacman, zypper). Installera det manuellt och kör skriptet igen."
  fi

  read -r -a pkgs <<<"$(packages_for "$need" "$version")"
  cmd=$(manual_install_command "${pkgs[@]}")

  if ! root_prefix; then
    die "$what saknas, och skriptet körs varken som root eller har sudo. Kör som root: $cmd"
  fi
  if ! confirm "$what saknas. Vill du installera det nu? ($cmd)"; then
    die "$what krävs. Installera manuellt med: $cmd"
  fi

  info "Installerar $what (${pkgs[*]}) …"
  run_pkg_install "${pkgs[@]}" \
    || die "Installationen av $what misslyckades. Kör manuellt: $cmd"
  hash -r
}

# ----------------------------------------------------------------------------
#  Förkrav: git och Python >= 3.10 med venv
# ----------------------------------------------------------------------------

# Sätter PYTHON_BIN till den bästa lämpliga Pythonversionen (3.13 rekommenderas
# av ComfyUI). Kan styras med miljövariabeln COMFY_PYTHON.
# Sätter även PYTHON_NO_VENV (version utan venv) och PYTHON_TOO_OLD.
find_python() {
  local candidates candidate version
  if [ -n "${COMFY_PYTHON:-}" ]; then
    candidates=("$COMFY_PYTHON")
  else
    candidates=(python3.13 python3.12 python3.11 python3.14 python3.10 python3)
  fi

  PYTHON_BIN="" PYTHON_NO_VENV="" PYTHON_TOO_OLD=""
  for candidate in "${candidates[@]}"; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    version=$("$candidate" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue
    if ! "$candidate" -c "import sys; sys.exit(0 if sys.version_info >= ($MIN_PYTHON_MAJOR, $MIN_PYTHON_MINOR) else 1)" 2>/dev/null; then
      PYTHON_TOO_OLD=${PYTHON_TOO_OLD:-$version}
      continue
    fi
    if "$candidate" -c "import venv, ensurepip" 2>/dev/null; then
      PYTHON_BIN=$(command -v "$candidate")
      return 0
    fi
    PYTHON_NO_VENV=${PYTHON_NO_VENV:-$version}
  done
  return 1
}

check_prerequisites() {
  info "Kontrollerar förkrav …"
  detect_pkg_manager

  if ! command -v git >/dev/null 2>&1; then
    ensure_packages "git" git
    command -v git >/dev/null 2>&1 \
      || die "git saknas fortfarande efter installationen. Installera det manuellt: $(manual_install_command git)"
  fi

  if ! find_python; then
    if [ -n "$PYTHON_NO_VENV" ]; then
      ensure_packages "Python-modulen venv (för Python $PYTHON_NO_VENV)" venv "$PYTHON_NO_VENV"
    elif [ -n "$PYTHON_TOO_OLD" ] && [ -z "${COMFY_PYTHON:-}" ]; then
      die "Python $PYTHON_TOO_OLD är för gammal – ComfyUI kräver Python >= $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR (3.13 rekommenderas). Installera en nyare version eller ange den med COMFY_PYTHON=/sökväg/till/python."
    else
      ensure_packages "Python 3 (>= $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR)" python
    fi
    find_python \
      || die "Ingen lämplig Python hittades efter installationen. ComfyUI kräver Python >= $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR med venv-modulen. Debian/Ubuntu: 'sudo apt-get install python3-venv'."
  fi

  ok "git: $(git --version | awk '{print $3}')"
  ok "Python: $PYTHON_BIN ($("$PYTHON_BIN" -c 'import platform; print(platform.python_version())'))"
}

# ----------------------------------------------------------------------------
#  Läs/skriv _CONFIG.json (med Python, inget beroende av jq)
# ----------------------------------------------------------------------------
config_get() {  # config_get FIL NYCKEL STANDARDVÄRDE
  "$PYTHON_BIN" - "$1" "$2" "$3" <<'PY' 2>/dev/null || printf '%s\n' "$3"
import json, sys
path, key, default = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as f:
        value = json.load(f).get(key, default)
except FileNotFoundError:
    value = default
print(value)
PY
}

write_config() {
  # Behåller eventuella extra nycklar som användaren lagt till själv
  "$PYTHON_BIN" - "$INSTALL_DIR/$CONFIG_NAME" "$CHANNEL" "$ORIGIN" "$TORCH_BACKEND" <<'PY'
import json, sys
path, channel, origin, torch_backend = sys.argv[1:5]
try:
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    if not isinstance(config, dict):
        config = {}
except (FileNotFoundError, json.JSONDecodeError):
    config = {}
config["_info"] = "Genererad av SETUP_COMFYUI.sh. channel: 'stable' (senaste release) eller 'latest' (senaste commit på master)."
config["channel"] = channel
config["origin"] = origin
config["torch_backend"] = torch_backend
config.setdefault("frontend_url_path", "/e")   # URL där origin/frontend serveras
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

# ----------------------------------------------------------------------------
#  Installationskatalog och kanal
# ----------------------------------------------------------------------------
is_comfyui_checkout() {
  [ -d "$1/.git" ] && [ -f "$1/main.py" ] && [ -f "$1/comfyui_version.py" ]
}

choose_install_dir() {
  if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR=$(ask "Var ska ComfyUI installeras?" "$ORIGIN/ComfyUI")
  fi
  # Expandera ~ och gör sökvägen absolut
  case $INSTALL_DIR in
    "~")   INSTALL_DIR=$HOME ;;
    \~/*) INSTALL_DIR="$HOME/${INSTALL_DIR#\~/}" ;;
  esac
  case $INSTALL_DIR in /*) ;; *) INSTALL_DIR="$PWD/$INSTALL_DIR" ;; esac
  INSTALL_DIR=${INSTALL_DIR%/}

  if is_comfyui_checkout "$INSTALL_DIR"; then
    MODE=update
    info "ComfyUI finns redan i $INSTALL_DIR – uppdaterar och konfigurerar om."
  elif [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    die "$INSTALL_DIR finns redan men är ingen ComfyUI-installation. Välj en tom eller ny katalog."
  else
    MODE=install
    info "ComfyUI installeras i $INSTALL_DIR"
  fi
}

choose_channel() {
  local current
  current=$(config_get "$INSTALL_DIR/$CONFIG_NAME" channel stable)
  if [ -z "$CHANNEL" ]; then
    CHANNEL=$(ask "Kanal: 'stable' (senaste release) eller 'latest' (senaste commit)?" "$current")
  fi
  case $CHANNEL in
    stable|latest) ;;
    *) die "Ogiltig kanal '$CHANNEL' – ange 'stable' eller 'latest'." ;;
  esac
  ok "Kanal: $CHANNEL"
}

# ----------------------------------------------------------------------------
#  Hämta ComfyUI
# ----------------------------------------------------------------------------
clone_comfyui() {
  [ "$MODE" = install ] || return 0
  info "Klonar ComfyUI från $COMFYUI_REPO_URL …"
  mkdir -p "$INSTALL_DIR"
  git clone "$COMFYUI_REPO_URL" "$INSTALL_DIR" \
    || die "Kunde inte klona ComfyUI. Kontrollera nätverksanslutningen."
  ok "ComfyUI klonad."
}

# ----------------------------------------------------------------------------
#  Python-miljö och PyTorch
# ----------------------------------------------------------------------------
create_venv() {
  local venv_py="$INSTALL_DIR/.venv/bin/python"
  if [ -x "$venv_py" ] && "$venv_py" -c 'import sys' 2>/dev/null; then
    ok "Pythonmiljö finns redan (.venv)."
    return
  fi
  if [ -d "$INSTALL_DIR/.venv" ]; then
    warn "Befintlig .venv fungerar inte (t.ex. efter Python-uppgradering) – skapas om."
    rm -rf "$INSTALL_DIR/.venv"
  fi
  info "Skapar Pythonmiljö i $INSTALL_DIR/.venv …"
  "$PYTHON_BIN" -m venv "$INSTALL_DIR/.venv" || die "Kunde inte skapa venv."
  "$venv_py" -m pip install --quiet --upgrade pip || die "Kunde inte uppgradera pip."
  ok "Pythonmiljö skapad."
}

# Gissa rätt PyTorch-variant utifrån hårdvaran
detect_torch_backend() {
  if [ "$(uname -s)" = Darwin ]; then
    echo default            # Apple: vanliga pip-paket (MPS ingår)
    return
  fi
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    # README: cu130 krävs för 20-serien och nyare; äldre kort (compute < 7.5)
    # och gamla drivrutiner (< 580) behöver cu126.
    local cap driver
    cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ')
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | cut -d. -f1)
    if [ -n "$cap" ] && awk -v c="$cap" 'BEGIN { exit !(c < 7.5) }'; then
      echo cuda-legacy
    elif [ -n "$driver" ] && [ "$driver" -lt 580 ] 2>/dev/null; then
      echo cuda-legacy
    else
      echo cuda
    fi
    return
  fi
  if command -v rocminfo >/dev/null 2>&1 || { [ -e /dev/kfd ] && grep -qs 0x1002 /sys/class/drm/card*/device/vendor; }; then
    echo rocm
    return
  fi
  echo cpu
}

install_torch() {
  local venv_py="$INSTALL_DIR/.venv/bin/python"
  local previous explicit=false
  previous=$(config_get "$INSTALL_DIR/$CONFIG_NAME" torch_backend "")

  if [ -n "$TORCH_BACKEND" ] && [ "$TORCH_BACKEND" != auto ]; then
    explicit=true
  elif [ -n "$previous" ]; then
    TORCH_BACKEND=$previous      # behåll tidigare val vid omkörning
  else
    TORCH_BACKEND=$(detect_torch_backend)
    info "Upptäckt PyTorch-variant: $TORCH_BACKEND (kan ändras med --torch)"
  fi

  local -a pip_args=(torch torchvision torchaudio)
  case $TORCH_BACKEND in
    cuda)        pip_args+=(--extra-index-url https://download.pytorch.org/whl/cu130) ;;
    cuda-legacy) pip_args+=(--extra-index-url https://download.pytorch.org/whl/cu126) ;;
    rocm)        pip_args+=(--index-url https://download.pytorch.org/whl/rocm7.2) ;;
    xpu)         pip_args+=(--index-url https://download.pytorch.org/whl/xpu) ;;
    cpu)         pip_args+=(--index-url https://download.pytorch.org/whl/cpu) ;;
    default)     ;;
    skip)        ok "Hoppar över PyTorch-installation (--torch skip)."; return ;;
    *)           die "Okänd PyTorch-variant '$TORCH_BACKEND'. Giltiga: auto, cuda, cuda-legacy, rocm, xpu, cpu, default, skip." ;;
  esac

  local has_torch=false
  "$venv_py" -c 'import torch' 2>/dev/null && has_torch=true

  if [ "$has_torch" = true ] && { [ "$explicit" = false ] || [ "$TORCH_BACKEND" = "$previous" ]; }; then
    ok "PyTorch finns redan ($("$venv_py" -c 'import torch; print(torch.__version__)'))."
    return
  fi
  if [ "$has_torch" = true ]; then
    info "Byter PyTorch-variant från '${previous:-okänd}' till '$TORCH_BACKEND' …"
    pip_args+=(--force-reinstall)
  else
    info "Installerar PyTorch ($TORCH_BACKEND) – det kan ta en stund …"
  fi
  "$venv_py" -m pip install --upgrade "${pip_args[@]}" \
    || die "PyTorch-installationen misslyckades. Prova en annan variant med --torch (t.ex. --torch cpu)."
  ok "PyTorch installerat ($("$venv_py" -c 'import torch; print(torch.__version__)'))."
}

# ----------------------------------------------------------------------------
#  Modellsökvägar: extra_model_paths.yaml -> origin/models
# ----------------------------------------------------------------------------
setup_model_paths() {
  local yaml="$INSTALL_DIR/extra_model_paths.yaml" entry key folders folder
  info "Skapar modellmappar i $ORIGIN/models …"

  # Säkerhetskopiera en egen (ej genererad) fil innan den skrivs över
  if [ -f "$yaml" ] && ! grep -qF "$GENERATED_MARKER" "$yaml"; then
    cp "$yaml" "$yaml.bak"
    warn "Befintlig extra_model_paths.yaml sparad som extra_model_paths.yaml.bak"
  fi

  {
    echo "$GENERATED_MARKER – ändringar skrivs över vid nästa körning."
    echo "# Pekar ComfyUI mot modellmapparna i origin."
    echo "origin:"
    printf '    base_path: "%s/models"\n' "$ORIGIN"
    echo "    is_default: true"
    for entry in "${MODEL_FOLDERS[@]}"; do
      key=${entry%%:*}
      folders=${entry#*:}
      if [ "${folders#*,}" = "$folders" ]; then
        printf '    %s: %s/\n' "$key" "$folders"
        mkdir -p "$ORIGIN/models/$folders"
      else
        printf '    %s: |\n' "$key"
        for folder in ${folders//,/ }; do
          printf '        %s/\n' "$folder"
          mkdir -p "$ORIGIN/models/$folder"
        done
      fi
    done
  } >"$yaml"
  ok "extra_model_paths.yaml skapad (base_path: $ORIGIN/models)."
}

# ----------------------------------------------------------------------------
#  Startskriptet (statiskt innehåll; läser allt från _CONFIG.json)
# ----------------------------------------------------------------------------
write_start_script() {
  local target="$INSTALL_DIR/$START_SCRIPT_NAME"
  cat >"$target" <<'START_EOF'
#!/usr/bin/env bash
# =============================================================================
#  _START_COMFYUI.sh – uppdaterar och startar ComfyUI
#  GENERERAD AV SETUP_COMFYUI.sh – ändringar skrivs över vid nästa setup.
# =============================================================================
#
#  Användning:
#    ./_START_COMFYUI.sh [--no-update] [--update-only] [argument till main.py …]
#
#    --no-update     starta utan att uppdatera
#    --update-only   uppdatera (git + pip + frontend) men starta inte
#    Övriga argument skickas vidare till ComfyUI, t.ex. --cpu eller --listen.
#
#  Kanal och origin läses från _CONFIG.json i samma katalog.
#  Utdata hamnar i /tmp/ComfyUI_output, som raderas när ComfyUI avslutas.
# =============================================================================

set -euo pipefail

readonly OUTPUT_DIR="/tmp/ComfyUI_output"
readonly FRONTEND_NODE_NAME="_origin_frontend"
readonly FRONTEND_MARKER=".generated_by_setup_comfyui"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mVARNING:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mFEL:\033[0m %s\n' "$*" >&2; exit 1; }

script_path=${BASH_SOURCE[0]}
if command -v realpath >/dev/null 2>&1; then
  script_path=$(realpath "$script_path")
fi
COMFY_DIR=$(cd -P "$(dirname "$script_path")" && pwd)
readonly COMFY_DIR
readonly CONFIG_FILE="$COMFY_DIR/_CONFIG.json"
readonly VENV_PY="$COMFY_DIR/.venv/bin/python"

[ -x "$VENV_PY" ] || die "Pythonmiljön saknas ($VENV_PY). Kör SETUP_COMFYUI.sh först."
[ -f "$CONFIG_FILE" ] || die "$CONFIG_FILE saknas. Kör SETUP_COMFYUI.sh först."

# Läs ett värde ur _CONFIG.json med venv-pythonen
config_get() {  # config_get NYCKEL STANDARDVÄRDE
  "$VENV_PY" - "$CONFIG_FILE" "$1" "$2" <<'PY' || die "Kunde inte läsa $CONFIG_FILE – är det giltig JSON?"
import json, sys
path, key, default = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    value = config.get(key, default)
except (OSError, ValueError, AttributeError) as error:
    sys.exit(f"  {error}")
print(value if value is not None else default)
PY
}

CHANNEL=$(config_get channel stable)
ORIGIN=$(config_get origin "")
FRONTEND_URL_PATH="/$(config_get frontend_url_path /e | sed 's#^/*##; s#/*$##')"
case $CHANNEL in
  stable|latest) ;;
  *) die "Ogiltig kanal '$CHANNEL' i $CONFIG_FILE – använd 'stable' eller 'latest'." ;;
esac

# ----------------------------------------------------------------------------
#  Argument
# ----------------------------------------------------------------------------
DO_UPDATE=true
DO_START=true
COMFY_ARGS=()
for arg in "$@"; do
  case $arg in
    --no-update)   DO_UPDATE=false ;;
    --update-only) DO_START=false ;;
    *)             COMFY_ARGS+=("$arg") ;;
  esac
done

# ----------------------------------------------------------------------------
#  Uppdatering av ComfyUI (git)
# ----------------------------------------------------------------------------
git_c() { git -C "$COMFY_DIR" "$@"; }

update_git() {
  info "Uppdaterar ComfyUI (kanal: $CHANNEL) …"

  # Lokala ändringar i spårade filer: uppdatera inte, men starta ändå
  local dirty
  dirty=$(git_c status --porcelain --untracked-files=no)
  if [ -n "$dirty" ]; then
    warn "ComfyUI har lokala ändringar – hoppar över git-uppdateringen:"
    printf '%s\n' "$dirty" | sed 's/^/      /' >&2
    warn "Spara undan med 'git -C \"$COMFY_DIR\" stash' eller kasta med 'git -C \"$COMFY_DIR\" checkout -- .' och kör igen."
    return 0
  fi

  if ! git_c fetch --quiet --tags --force --prune origin; then
    warn "Kunde inte hämta uppdateringar (offline?) – startar nuvarande version."
    return 0
  fi

  local before target
  before=$(git_c rev-parse HEAD)

  if [ "$CHANNEL" = stable ]; then
    # Högsta versions-tagg av formen vX.Y.Z
    target=$(git_c tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
    [ -n "$target" ] || die "Hittade ingen release-tagg (vX.Y.Z) i ComfyUI-repot."
    git_c -c advice.detachedHead=false checkout --quiet "$target" \
      || die "Kunde inte checka ut $target."
  else
    # Standardgren på GitHub (master)
    local remote_ref branch
    remote_ref=$(git_c symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)
    branch=${remote_ref#origin/}
    if git_c show-ref --verify --quiet "refs/heads/$branch" \
       && ! git_c merge-base --is-ancestor "$branch" "$remote_ref"; then
      warn "Lokala commits på '$branch' som inte finns på GitHub – hoppar över uppdateringen."
      return 0
    fi
    git_c checkout --quiet -B "$branch" "$remote_ref" \
      || die "Kunde inte checka ut $remote_ref."
    git_c branch --quiet --set-upstream-to="$remote_ref" "$branch" >/dev/null 2>&1 || true
    target="$branch ($(git_c rev-parse --short HEAD))"
  fi

  if [ "$before" = "$(git_c rev-parse HEAD)" ]; then
    ok "ComfyUI är redan aktuell: $target"
  else
    ok "ComfyUI uppdaterad till $target"
  fi
}

# ----------------------------------------------------------------------------
#  Pythonberoenden – installeras bara om requirements.txt har ändrats
# ----------------------------------------------------------------------------
update_requirements() {
  local req="$COMFY_DIR/requirements.txt" stamp="$COMFY_DIR/.venv/.requirements.sha256"
  local new_hash old_hash=""
  new_hash=$("$VENV_PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$req")
  [ -f "$stamp" ] && old_hash=$(cat "$stamp")
  if [ "$new_hash" = "$old_hash" ]; then
    ok "Pythonberoenden är aktuella."
    return 0
  fi
  info "Installerar Pythonberoenden (requirements.txt) …"
  "$VENV_PY" -m pip install --quiet -r "$req" \
    || die "pip install -r requirements.txt misslyckades."
  printf '%s\n' "$new_hash" >"$stamp"
  ok "Pythonberoenden installerade."
}

# ----------------------------------------------------------------------------
#  Egen frontend: origin/frontend serveras live under /e/
#
#  En liten genererad custom node (custom_nodes/_origin_frontend) registrerar
#  en statisk aiohttp-route som pekar direkt på origin/frontend – ingen
#  kopiering, så ändringar syns direkt (ladda om sidan i webbläsaren).
#  Noden sätter medvetet INGEN WEB_DIRECTORY: då skulle ComfyUI ladda in alla
#  .js-filer som tillägg i sitt eget gränssnitt, och sidorna är fristående.
#  Webbroten i pip-paketet comfyui-frontend-package rörs inte.
# ----------------------------------------------------------------------------
setup_frontend_node() {
  local node_dir="$COMFY_DIR/custom_nodes/$FRONTEND_NODE_NAME"

  if [ -d "$node_dir" ] && [ ! -f "$node_dir/$FRONTEND_MARKER" ]; then
    warn "$node_dir finns men är inte genererad av setup – rör den inte."
    return 0
  fi

  mkdir -p "$node_dir"
  touch "$node_dir/$FRONTEND_MARKER"
  rm -rf "$node_dir/web" "$node_dir/web.tmp"   # rester från äldre kopierande version
  cat >"$node_dir/__init__.py" <<'PY'
# Genererad av _START_COMFYUI.sh – skrivs över vid varje start.
#
# Serverar origin/frontend live (ingen kopiering) under en egen URL, som
# standard /e/. Sökvägarna läses från _CONFIG.json i ComfyUI-katalogen.
# Ingen WEB_DIRECTORY: sidornas .js-filer ska inte laddas in i ComfyUI.
import json
import logging
import os

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}

_LOG_PREFIX = "[origin_frontend]"


def _register_frontend_route():
    comfy_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    config_path = os.path.join(comfy_dir, "_CONFIG.json")
    try:
        with open(config_path, encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, ValueError) as error:
        logging.warning("%s Kunde inte läsa %s: %s", _LOG_PREFIX, config_path, error)
        return

    origin = config.get("origin") or ""
    url_path = "/" + str(config.get("frontend_url_path") or "e").strip("/")
    if url_path == "/":
        url_path = "/e"   # webbroten tillhör ComfyUI
    frontend_dir = os.path.join(origin, "frontend")
    if not origin or not os.path.isdir(frontend_dir):
        logging.info("%s Ingen frontend-mapp (%s) – inget serveras.", _LOG_PREFIX, frontend_dir)
        return

    from aiohttp import web
    from server import PromptServer

    routes = PromptServer.instance.routes

    # /e och /e/ -> index.html om den finns (statiska routes visar inte index)
    async def index_redirect(request):
        if os.path.isfile(os.path.join(frontend_dir, "index.html")):
            raise web.HTTPFound(url_path + "/index.html")
        raise web.HTTPNotFound()

    routes.get(url_path)(index_redirect)
    routes.get(url_path + "/")(index_redirect)
    # follow_symlinks: symlänkar inuti origin/frontend får peka utanför mappen.
    # aiohttp stoppar fortfarande "../"-försök i själva URL:en.
    routes.static(url_path, frontend_dir, follow_symlinks=True)
    logging.info("%s Serverar %s på %s/", _LOG_PREFIX, frontend_dir, url_path)


_register_frontend_route()
PY

  if [ -n "$ORIGIN" ] && [ -d "$ORIGIN/frontend" ]; then
    ok "Egen frontend serveras live från $ORIGIN/frontend på $FRONTEND_URL_PATH/"
  else
    info "Ingen frontend-mapp (${ORIGIN:-origin saknas}/frontend) – inget serveras på $FRONTEND_URL_PATH/."
  fi
}

# ----------------------------------------------------------------------------
#  Körning
# ----------------------------------------------------------------------------
if [ "$DO_UPDATE" = true ]; then
  update_git
  update_requirements
fi
setup_frontend_node

# Städa bort utdatamappen när ComfyUI avslutas (normalt, Ctrl+C eller SIGTERM)
cleanup() {
  rm -rf -- "$OUTPUT_DIR"
  echo "Utdatamappen $OUTPUT_DIR raderad."
}

# Python körs i bakgrunden (inte exec) så att skalet kan fånga signaler och
# städa efteråt. Bakgrundsprocesser ignorerar SIGINT i skript, därför
# vidarebefordras både Ctrl+C och SIGTERM som SIGTERM till ComfyUI.
# Tredje signalen dödar processen hårt (SIGKILL).
comfy_pid=""
signal_count=0
forward_signal() {
  signal_count=$((signal_count + 1))
  [ -n "$comfy_pid" ] || exit 130
  if [ "$signal_count" -ge 3 ]; then
    kill -KILL "$comfy_pid" 2>/dev/null || true
  else
    echo
    info "Avslutar ComfyUI …"
    kill -TERM "$comfy_pid" 2>/dev/null || true
  fi
}

run_comfyui() {
  trap cleanup EXIT
  trap forward_signal INT TERM HUP

  info "Startar ComfyUI (utdata: $OUTPUT_DIR) …"
  mkdir -p "$OUTPUT_DIR"
  cd "$COMFY_DIR"
  "$VENV_PY" main.py --output-directory "$OUTPUT_DIR" ${COMFY_ARGS[@]+"${COMFY_ARGS[@]}"} &
  comfy_pid=$!

  # wait avbryts av fångade signaler – vänta tills processen verkligen är borta
  local exit_code=0
  while :; do
    wait "$comfy_pid" && exit_code=0 || exit_code=$?
    kill -0 "$comfy_pid" 2>/dev/null || break
  done
  return "$exit_code"
}

if [ "$DO_START" = true ]; then
  run_comfyui
fi
START_EOF
  chmod +x "$target"
  ok "$START_SCRIPT_NAME skapad."
}

# Håll "git status" ren: genererade filer ska inte synas som ändringar
exclude_generated_files() {
  local exclude="$INSTALL_DIR/.git/info/exclude" name
  mkdir -p "$(dirname "$exclude")"
  touch "$exclude"
  for name in "/$START_SCRIPT_NAME" "/$CONFIG_NAME" "/extra_model_paths.yaml.bak"; do
    grep -qxF "$name" "$exclude" || printf '%s\n' "$name" >>"$exclude"
  done
}

# ----------------------------------------------------------------------------
#  Huvudflöde
# ----------------------------------------------------------------------------
main() {
  echo
  info "ComfyUI-setup (origin: $ORIGIN)"
  check_prerequisites
  choose_install_dir
  choose_channel
  clone_comfyui
  create_venv
  install_torch
  write_config
  ok "$CONFIG_NAME skapad."
  setup_model_paths
  write_start_script
  exclude_generated_files

  # Själva uppdateringen (rätt git-ref, requirements, frontend) görs av
  # startskriptet så att logiken bara finns på ett ställe.
  "$INSTALL_DIR/$START_SCRIPT_NAME" --update-only

  echo
  ok "Klart! Starta ComfyUI med:"
  printf '      %q\n' "$INSTALL_DIR/$START_SCRIPT_NAME"
  if [ -d "$ORIGIN/frontend" ]; then
    local url_path
    url_path=$(config_get "$INSTALL_DIR/$CONFIG_NAME" frontend_url_path /e | sed 's#^/*##; s#/*$##')
    echo "    Egen frontend: http://127.0.0.1:8188/${url_path:-e}/"
  fi
  return 0
}

main
