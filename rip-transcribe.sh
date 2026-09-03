#!/usr/bin/env bash
# ==============================================================================
# rip-transcribe.sh - All-in-one Lecture Ripper, Slide Extractor, Transcriber & PDF Generator
# Optimized for macOS (Apple Silicon) & Linux/AMD
# ==============================================================================

set -euo pipefail

# --- Default Configurations ---
MODEL="large-v3-turbo"        # large-v3-turbo (default) / large-v3 / medium / small
LANG="fi"
HEADERS=""
USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)"
OLLAMA_MODEL="qwen3.6:35b-a3b"  # or qwen3.8, llama3.2, etc.
OUT_PREFIX=""                 # Auto-computed with running number if empty
SUMMARY_FILE=""               # Auto-computed with running number if empty
CUSTOM_NAME=""                # User-supplied base name (-n / --name)
SLIDES_DIR=""                 # Auto-computed per lecture if empty
EXTRACT_SLIDES=true
GENERATE_PDF=true
APPLY_SPEECH_FILTER=true
SKIP_SUMMARY=false
ONLY_SUMMARY=false
VENV_DIR="whisper-env"

# --- Help / Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <SOURCE_URL_OR_FILE>

Arguments:
  <SOURCE_URL_OR_FILE>          Stream URL (m3u8/mp4) or local video/audio file.

Options:
  -n, --name <name>             Base name for output artefacts (default: derived from input file)
  -s, --summary-file <filename> Explicit summary markdown filename (overrides auto-numbering)
  -o, --output <prefix>         Explicit prefix for transcript files (.txt, .srt)
  -H, --headers <string>        Custom HTTP headers for ffmpeg (e.g. "Referer: https://...")
  -m, --model <model_name>      Whisper model: large-v3-turbo (default), large-v3, medium, small, base
  -l, --language <code>         Transcription language (default: fi)
  --slides-dir <dir>            Directory for slide screenshots (default: slides/<XX_name>)
  --no-slides                   Skip slide extraction from video
  --no-pdf                      Skip PDF generation from Markdown summary
  --ollama-model <model>        Ollama model for summary (default: qwen3.6:35b-a3b)
  --only-summary                Skip slide & audio extraction, run Ollama cleanup & summary only
  --no-filter                   Disable audio highpass/lowpass/loudnorm preprocessing
  --skip-summary                Skip Ollama summary generation (transcribe only)
  -h, --help                    Show this help message

Output Naming Convention:
  When run sequentially, files are automatically assigned a running number:
    01_lecture_yhteenveto.md
    01_lecture_yhteenveto.pdf
    01_lecture.txt
    01_lecture_clean.txt
    01_lecture.srt
    slides/01_lecture/

Examples:
  # Auto-numbered summary and PDF from local file:
  ./$(basename "$0") lecture.mp4

  # With custom lecture name:
  ./$(basename "$0") -n ai_lecture1 "https://example.com/stream/index.m3u8"

  # Explicit summary file name:
  ./$(basename "$0") -s my_summary.md lecture.mp4
EOF
    exit 1
}

# --- Parse Arguments ---
if [[ $# -eq 0 ]]; then
    usage
fi

SOURCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)
            CUSTOM_NAME="$2"; shift 2 ;;
        -s|--summary-file)
            SUMMARY_FILE="$2"; shift 2 ;;
        -o|--output)
            OUT_PREFIX="$2"; shift 2 ;;
        -H|--headers)
            HEADERS="$2"; shift 2 ;;
        -m|--model)
            MODEL="$2"; shift 2 ;;
        -l|--language)
            LANG="$2"; shift 2 ;;
        --slides-dir)
            SLIDES_DIR="$2"; shift 2 ;;
        --no-slides)
            EXTRACT_SLIDES=false; shift ;;
        --no-pdf)
            GENERATE_PDF=false; shift ;;
        --ollama-model)
            OLLAMA_MODEL="$2"; shift 2 ;;
        --only-summary|--summary-only)
            ONLY_SUMMARY=true; shift ;;
        --no-filter)
            APPLY_SPEECH_FILTER=false; shift ;;
        --skip-summary)
            SKIP_SUMMARY=true; shift ;;
        -h|--help)
            usage ;;
        -*)
            echo "[!] Unknown option: $1" >&2; usage ;;
        *)
            SOURCE="$1"; shift ;;
    esac
done

if [[ -z "$SOURCE" ]]; then
    echo "[!] Error: No source URL or file provided." >&2
    usage
fi

if [[ "$SOURCE" =~ \.txt$ ]]; then
    ONLY_SUMMARY=true
fi

# --- Determine Base Name & Running Number ---
if [[ -n "$CUSTOM_NAME" ]]; then
    BASE_NAME="${CUSTOM_NAME%.*}"
else
    # Extract filename without query parameters
    CLEAN_SRC="${SOURCE%%\?*}"
    SRC_FILE=$(basename "$CLEAN_SRC")
    BASE_NAME="${SRC_FILE%.*}"
    BASE_NAME="${BASE_NAME%_clean}"
    BASE_NAME="${BASE_NAME%_korjattu}"
    # Fallback if generic stream playlist name
    if [[ "$BASE_NAME" =~ ^(index|master|stream|playlist|video|output)$ ]] || [[ -z "$BASE_NAME" ]]; then
        BASE_NAME="luento"
    fi
fi

# Sanitize base name (spaces and special characters to underscores)
BASE_NAME=$(echo "$BASE_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')

# If base name already starts with a two-digit prefix (e.g. 01_02_luento), preserve it
if [[ "$BASE_NAME" =~ ^[0-9]{2}_ ]]; then
    RUN_NUM="${BASE_NAME:0:2}"
    BASE_NAME="${BASE_NAME:3}"
else
    # Find next running sequential index across existing directories and files
    NEXT_NUM=1
    for item in [0-9][0-9]_*; do
        if [[ -e "$item" ]]; then
            num="${item%%_*}"
            if [[ "$num" =~ ^[0-9]+$ ]]; then
                num_val=$((10#$num))
                if (( num_val >= NEXT_NUM )); then
                    NEXT_NUM=$((num_val + 1))
                fi
            fi
        fi
    done
    RUN_NUM=$(printf "%02d" "$NEXT_NUM")
fi

# Configure output filenames if not explicitly overridden
if [[ -z "$SUMMARY_FILE" ]]; then
    SUMMARY_FILE="${RUN_NUM}_${BASE_NAME}_yhteenveto.md"
fi

PDF_FILE="${SUMMARY_FILE%.*}.pdf"

if [[ -z "$OUT_PREFIX" ]]; then
    OUT_PREFIX="${RUN_NUM}_${BASE_NAME}"
fi

if [[ -z "$SLIDES_DIR" ]]; then
    SLIDES_DIR="slides/${RUN_NUM}_${BASE_NAME}"
fi

# --- Check Prerequisites ---
for cmd in ffmpeg python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[!] Error: Required tool '$cmd' is not installed or not in PATH." >&2
        exit 1
    fi
done

if [[ "$SKIP_SUMMARY" = false ]] && ! command -v ollama &>/dev/null; then
    echo "[!] Warning: 'ollama' not found. Skipping summary generation." >&2
    SKIP_SUMMARY=true
fi

# --- Setup Python Environment ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -f "$VIRTUAL_ENV/bin/python3" ]]; then
    PYTHON_EXEC="$VIRTUAL_ENV/bin/python3"
elif [[ -f "$SCRIPT_DIR/$VENV_DIR/bin/python3" ]]; then
    PYTHON_EXEC="$SCRIPT_DIR/$VENV_DIR/bin/python3"
elif [[ -f "$VENV_DIR/bin/python3" ]]; then
    PYTHON_EXEC="$VENV_DIR/bin/python3"
else
    echo "[*] Initializing virtualenv in '$SCRIPT_DIR/$VENV_DIR'..."
    python3 -m venv "$SCRIPT_DIR/$VENV_DIR"
    "$SCRIPT_DIR/$VENV_DIR/bin/pip" install --upgrade pip
    PYTHON_EXEC="$SCRIPT_DIR/$VENV_DIR/bin/python3"
fi

# Ensure requirements from requirements.txt are installed
if [[ -f "$SCRIPT_DIR/requirements.txt" ]]; then
    if ! "$PYTHON_EXEC" -c "import mlx_whisper, markdown" &>/dev/null; then
        echo "[*] Installing dependencies from requirements.txt into $PYTHON_EXEC..."
        "$PYTHON_EXEC" -m pip install -r "$SCRIPT_DIR/requirements.txt"
    fi
fi

echo "[*] Using Python: $PYTHON_EXEC"

# --- Step 1/5: Extract Slide Images from Video ---
if [[ "$ONLY_SUMMARY" = false ]] && [[ "$EXTRACT_SLIDES" = true ]]; then
    echo "==> [1/5] Detecting & extracting lecture slides into '$SLIDES_DIR/'..."
    $PYTHON_EXEC "$SCRIPT_DIR/extract_slides.py" "$SOURCE" -o "$SLIDES_DIR" || {
        echo "[!] Note: Could not extract slides (audio-only source or unsupported video stream). Continuing."
        EXTRACT_SLIDES=false
    }
fi

# --- Step 2/5: Extract & Preprocess Audio ---
if [[ "$ONLY_SUMMARY" = false ]]; then
    TEMP_AUDIO=$(mktemp -t lecture_audio_XXXXXX).wav
    trap 'rm -f "$TEMP_AUDIO"' EXIT INT TERM

    echo "==> [2/5] Extracting & preprocessing clean speech audio..."

    # Build ffmpeg options
    FFMPEG_ARGS=(
        -y
        -nostdin
        -loglevel warning
    )

    # Only add network reconnection and headers if source is a remote URL
    if [[ "$SOURCE" =~ ^https?:// ]]; then
        FFMPEG_ARGS+=(
            -user_agent "$USER_AGENT"
            -reconnect 1
            -reconnect_at_eof 1
            -reconnect_streamed 1
            -reconnect_delay_max 5
        )
        if [[ -n "$HEADERS" ]]; then
            FFMPEG_ARGS+=(-headers "$HEADERS")
        fi
    fi

    FFMPEG_ARGS+=(-i "$SOURCE" -vn -sn -dn)

    # Audio filter: speech bandpass (75Hz-7500Hz) and speech normalization
    if [[ "$APPLY_SPEECH_FILTER" = true ]]; then
        FFMPEG_ARGS+=(-af "highpass=f=75,lowpass=f=7500,speechnorm=e=4:r=0.0001:l=1")
    fi

    # Whisper native format: 16kHz mono PCM 16-bit
    FFMPEG_ARGS+=(-ar 16000 -ac 1 -c:a pcm_s16le "$TEMP_AUDIO")

    ffmpeg "${FFMPEG_ARGS[@]}"

    AUDIO_SIZE=$(ls -lh "$TEMP_AUDIO" | awk '{print $5}')
    echo "    Extracted clean speech audio: $AUDIO_SIZE"

    # --- Step 3/5: Transcription ---
    echo "==> [3/5] Transcribing audio with mlx-whisper ($MODEL, lang=$LANG)..."

    TRANSCRIBE_CMD=(
        "$PYTHON_EXEC" "$SCRIPT_DIR/transcribe.py"
        "$TEMP_AUDIO"
        --model "$MODEL"
        --language "$LANG"
        --output-prefix "$OUT_PREFIX"
    )

    if [[ "$EXTRACT_SLIDES" = true ]] && [[ -d "$SLIDES_DIR" ]]; then
        TRANSCRIBE_CMD+=(--slides-dir "$SLIDES_DIR")
    fi

    "${TRANSCRIBE_CMD[@]}"
fi

# --- Step 4/5: 2-Pass Ollama Cleanup & Synopsis ---
if [[ "$SKIP_SUMMARY" = false ]]; then
    CLEAN_TRANSCRIPT="${OUT_PREFIX}_clean.txt"

    if [[ ! -f "$CLEAN_TRANSCRIPT" ]]; then
        CLEAN_TRANSCRIPT="${OUT_PREFIX}.txt"
    fi

    if [[ ! -f "$CLEAN_TRANSCRIPT" ]]; then
        echo "[!] Error: Transcript file '$CLEAN_TRANSCRIPT' not found." >&2
        exit 1
    fi

    KORJATTU_TRANSCRIPT="${OUT_PREFIX}_korjattu.txt"
    RAW_SUMMARY="${OUT_PREFIX}_yhteenveto_raw.md"

    # Pass 4a: Proofread and fix voice recognition errors while preserving slide markers
    echo "==> [4a/5] Fixing speech recognition artefacts & Finnish grammar with Ollama ($OLLAMA_MODEL)..."
    (
        echo "Olet ammattitaitoinen suomen kielen ja teknisten tekstien oikolukija."
        echo "Alla on automaattisella puheentunnistuksella (Whisper) litteroitu luentoteksti, jossa on mukana diakuvaviittauksia muodossa:"
        echo "![Dia (MM:SS)](slides/...)"
        echo ""
        echo "Tehtäväsi:"
        echo "1. Korjaa puheentunnistuksen virheet:"
        echo "   - Väärin kuullut sanat ja foneettiset virheet (esim. opettajan nimi, oppilaitokset, termit)"
        echo "   - Yhdyssanavirheet ja kielioppi"
        echo "   - Turhat täytesanat ja takeltelut (esim. 'niinku', 'tota noin'), säilyttäen puhujan asiasisällön ja tyylin"
        echo "2. TÄRKEÄÄ: Säilytä KAIKKI diakuvaviittaukset (muodossa ![Dia...](...)) täsmälleen oikeilla paikoillaan omilla riveillään."
        echo "3. Älä keksi uutta asiaa äläkä poista asiaan kuuluvaa tietoa."
        echo "4. ÄLÄ lisää mitään tervehdystä, päättelyä tai saatesanoja. Tulosta VAIN korjattu teksti dioineen."
        echo ""
        echo "Luentoteksti ja diat:"
        cat "$CLEAN_TRANSCRIPT"
    ) | ollama run "$OLLAMA_MODEL" --nowordwrap --think=false | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' > "$KORJATTU_TRANSCRIPT"

    echo "[+] Cleaned transcript saved to '$KORJATTU_TRANSCRIPT'."

    # Pass 4b: Generate structured course synopsis with slide placements
    echo "==> [4b/5] Drafting structured course synopsis with Ollama ($OLLAMA_MODEL)..."
    (
        echo "Olet yliopistotason opiskeluassistentti. Alla on siistitty ja korjattu luentotranskriptio sekä esityksen diojen kuvamerkinnät muodossa ![Dia](...)."
        echo "Tee tekstistä selkeä, jäsennelty ja ammattimainen Markdown-opintoyhteenveto suomeksi (enintään 2-3 sivua)."
        echo "Sijoita aiheeseen liittyvät diojen kuvamerkinnät luontevasti väliotsikoiden alle havainnollistamaan tekstiä."
        echo ""
        echo "Käytä seuraavaa rakennetta:"
        echo "## Tiivistelmä"
        echo "## Keskeiset käsitteet ja aiheet"
        echo "## Tehtävät ja harjoitustyöt"
        echo "## Arviointiperusteet ja vaatimukset"
        echo "## Tärkeät päivämäärät ja deadlinet"
        echo ""
        echo "Luentoteksti ja diat:"
        cat "$KORJATTU_TRANSCRIPT"
    ) | ollama run "$OLLAMA_MODEL" --nowordwrap --think=false | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' > "$RAW_SUMMARY"

    # Pass 4c: Polish & Quality Review (Academic style, flawless grammar, clean layout)
    echo "==> [4c/5] Polishing & reviewing final lecture summary with Ollama ($OLLAMA_MODEL)..."
    (
        echo "Olet akateeminen kielenhuoltaja ja opiskelumateriaalien toimittaja."
        echo "Alla on luonnos luentoyhteenvedosta, jossa on mukana diakuvia muodossa ![Dia...](...)."
        echo ""
        echo "Tehtäväsi:"
        echo "1. Viimeistele teksti: poista toistot, korjaa lauserakenteet ja sanamuodot luontevaksi, huolitelluksi asiatyyliksi."
        echo "2. Varmista, että kurssin vaatimukset, tehtävänanto (sivumäärät, arviointiasteikko) ja aikataulut ovat selkeitä ja helppolukuisia (käytä selkeitä luettelomerkkejä ja lihavointeja)."
        echo "3. Säilytä KAIKKI diakuvamerkinnät ![Dia...](...) paikoillaan."
        echo "4. ÄLÄ lisää mitään johdanto- tai lopetussanoja ('Tässä on korjattu versio...'). Tulosta suoraan valmis Markdown-dokumentti."
        echo ""
        echo "Luonnos:"
        cat "$RAW_SUMMARY"
    ) | ollama run "$OLLAMA_MODEL" --nowordwrap --think=false | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' > "$SUMMARY_FILE"

    rm -f "$RAW_SUMMARY"
    echo "[+] Final polished summary generated into '$SUMMARY_FILE'."

    # --- Step 5/5: Deduce Heading & Organize into Dedicated Lecture Folder ---
    DEDUCED_SLUG=$("$PYTHON_EXEC" -c "
import sys, re
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        text = f.read()
    m = re.search(r'^#\s+(.+)$', text, re.MULTILINE)
    if m:
        title = m.group(1).strip()
        cleaned = re.sub(r'[\s–—-]+(Opintoyhteenveto|Luentoyhteenveto|Yhteenveto|Tiivistelmä|Luento).*', '', title, flags=re.IGNORECASE).strip()
        slug = cleaned.lower().replace('ä', 'a').replace('ö', 'o').replace('å', 'a')
        slug = re.sub(r'[^a-z0-9]+', '_', slug).strip('_')
        if slug:
            print(slug)
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
" "$SUMMARY_FILE" 2>/dev/null || true)

    if [[ -n "$DEDUCED_SLUG" ]]; then
        TARGET_DIR="${RUN_NUM}_${DEDUCED_SLUG}"
    else
        TARGET_DIR="${RUN_NUM}_${BASE_NAME}"
    fi

    echo "==> Organizing all lecture artefacts into dedicated folder '$TARGET_DIR/'..."
    mkdir -p "$TARGET_DIR"

    # Move slide images into $TARGET_DIR/slides/
    if [[ -d "$SLIDES_DIR" ]]; then
        mkdir -p "$TARGET_DIR/slides"
        cp -r "$SLIDES_DIR"/* "$TARGET_DIR/slides/" 2>/dev/null || true
        rm -rf "$SLIDES_DIR"
        rmdir slides 2>/dev/null || true
    fi

    # Update slide image references to relative 'slides/' inside the lecture folder
    for txt_file in "$SUMMARY_FILE" "${OUT_PREFIX}_clean.txt" "${OUT_PREFIX}_korjattu.txt" "${OUT_PREFIX}.txt"; do
        if [[ -f "$txt_file" ]]; then
            sed -i '' -E "s|slides/${OUT_PREFIX}/|slides/|g; s|${SLIDES_DIR}/|slides/|g" "$txt_file" 2>/dev/null || true
        fi
    done

    # Move text, transcript and subtitle files into $TARGET_DIR/
    NEW_SUMMARY_FILE="$TARGET_DIR/${TARGET_DIR}_yhteenveto.md"
    mv "$SUMMARY_FILE" "$NEW_SUMMARY_FILE"
    SUMMARY_FILE="$NEW_SUMMARY_FILE"

    if [[ -f "${OUT_PREFIX}.txt" ]]; then
        mv "${OUT_PREFIX}.txt" "$TARGET_DIR/${TARGET_DIR}.txt"
    fi
    if [[ -f "${OUT_PREFIX}_clean.txt" ]]; then
        mv "${OUT_PREFIX}_clean.txt" "$TARGET_DIR/${TARGET_DIR}_clean.txt"
    fi
    if [[ -f "${OUT_PREFIX}_korjattu.txt" ]]; then
        mv "${OUT_PREFIX}_korjattu.txt" "$TARGET_DIR/${TARGET_DIR}_korjattu.txt"
    fi
    if [[ -f "${OUT_PREFIX}.srt" ]]; then
        mv "${OUT_PREFIX}.srt" "$TARGET_DIR/${TARGET_DIR}.srt"
    fi

    # Move source video file into $TARGET_DIR/ if it is a local file
    SRC_EXT="mp4"
    if [[ -f "$SOURCE" ]] && [[ "$SOURCE" =~ \.(mp4|mkv|mov|webm|mp3|wav|m4a)$ ]]; then
        SRC_EXT="${SOURCE##*.}"
        TARGET_VIDEO="$TARGET_DIR/${TARGET_DIR}.${SRC_EXT}"
        if [[ "$SOURCE" != "$TARGET_VIDEO" ]]; then
            mv "$SOURCE" "$TARGET_VIDEO"
        fi
    fi

    # Render PDF directly inside the lecture folder
    PDF_FILE="$TARGET_DIR/${TARGET_DIR}_yhteenveto.pdf"
    if [[ "$GENERATE_PDF" = true ]]; then
        echo "==> Rendering styled PDF document with embedded slides inside '$TARGET_DIR/'..."
        $PYTHON_EXEC "$SCRIPT_DIR/md_to_pdf.py" "$SUMMARY_FILE" -o "$PDF_FILE" || {
            echo "[!] Note: Automatic PDF export skipped."
        }
    fi
fi

# --- Final Artefact Output Cues ---
echo ""
echo "================================================================="
echo "🎉 Pipeline Finished! All lecture artefacts organized into:"
echo "   📁 ${TARGET_DIR:-$OUT_PREFIX}/"
echo "================================================================="
FINAL_DIR="${TARGET_DIR:-$OUT_PREFIX}"
if [[ -f "${FINAL_DIR}/${FINAL_DIR}.${SRC_EXT:-mp4}" ]]; then
    VID_SIZE=$(ls -lh "${FINAL_DIR}/${FINAL_DIR}.${SRC_EXT:-mp4}" | awk '{print $5}')
    echo "  🎬 Video File             : ${FINAL_DIR}/${FINAL_DIR}.${SRC_EXT:-mp4} ($VID_SIZE)"
fi
if [[ -d "${FINAL_DIR}/slides" ]]; then
    SLIDE_COUNT=$(ls -1 "${FINAL_DIR}/slides"/slide_*.jpg 2>/dev/null | wc -l | tr -d ' ')
    echo "  🖼️ Extracted Slides       : ${FINAL_DIR}/slides/ ($SLIDE_COUNT slide images)"
fi
if [[ -f "${FINAL_DIR}/${FINAL_DIR}.txt" ]]; then
    RAW_SIZE=$(ls -lh "${FINAL_DIR}/${FINAL_DIR}.txt" | awk '{print $5}')
    echo "  📄 Timestamped Transcript : ${FINAL_DIR}/${FINAL_DIR}.txt ($RAW_SIZE)"
fi
if [[ -f "${FINAL_DIR}/${FINAL_DIR}_clean.txt" ]]; then
    CLEAN_SIZE=$(ls -lh "${FINAL_DIR}/${FINAL_DIR}_clean.txt" | awk '{print $5}')
    echo "  📄 Clean Text & Slides    : ${FINAL_DIR}/${FINAL_DIR}_clean.txt ($CLEAN_SIZE)"
fi
if [[ -f "${FINAL_DIR}/${FINAL_DIR}_korjattu.txt" ]]; then
    KORJATTU_SIZE=$(ls -lh "${FINAL_DIR}/${FINAL_DIR}_korjattu.txt" | awk '{print $5}')
    echo "  ✨ Proofread Transcript   : ${FINAL_DIR}/${FINAL_DIR}_korjattu.txt ($KORJATTU_SIZE)"
fi
if [[ -f "${FINAL_DIR}/${FINAL_DIR}.srt" ]]; then
    SRT_SIZE=$(ls -lh "${FINAL_DIR}/${FINAL_DIR}.srt" | awk '{print $5}')
    echo "  🎬 Subtitle Track (SRT)   : ${FINAL_DIR}/${FINAL_DIR}.srt ($SRT_SIZE)"
fi
if [[ -f "$SUMMARY_FILE" ]]; then
    SUM_SIZE=$(ls -lh "$SUMMARY_FILE" | awk '{print $5}')
    SUM_WORDS=$(wc -w < "$SUMMARY_FILE" | tr -d ' ')
    echo "  📝 Markdown Synopsis      : $SUMMARY_FILE ($SUM_SIZE, ~$SUM_WORDS words)"
fi
if [[ -f "$PDF_FILE" ]]; then
    PDF_SIZE=$(ls -lh "$PDF_FILE" | awk '{print $5}')
    echo "  📑 Rendered PDF Document  : $PDF_FILE ($PDF_SIZE)"
fi
echo "================================================================="
