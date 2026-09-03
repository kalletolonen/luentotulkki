#!/usr/bin/env bash
# ==============================================================================
# summarize.sh - 2-Pass Ollama Cleanup, Summary & PDF Generator
#
# Pass 1: Uses Qwen to fix Whisper speech-to-text artefacts, phonetic typos,
#         compound word mistakes, and grammar while preserving slide tags.
# Pass 2: Generates a well-structured lecture summary in Finnish.
# Pass 3: Compiles the summary with slide images into a styled PDF.
# ==============================================================================

set -euo pipefail

OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.6:35b-a3b}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find Python executable (prefer whisper-env virtualenv if present)
PYTHON_EXEC="python3"
if [[ -f "$SCRIPT_DIR/whisper-env/bin/python3" ]]; then
    PYTHON_EXEC="$SCRIPT_DIR/whisper-env/bin/python3"
fi

# Determine input file
INPUT_FILE="${1:-}"
if [[ -z "$INPUT_FILE" ]]; then
    # Auto-detect latest clean transcript file
    INPUT_FILE=$(ls -t *_clean.txt 2>/dev/null | head -n 1 || true)
    if [[ -z "$INPUT_FILE" ]]; then
        INPUT_FILE=$(ls -t *.txt 2>/dev/null | grep -v "_korjattu" | head -n 1 || true)
    fi
fi

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
    echo "[!] Error: No transcript file found. Usage: $0 <transcript_clean.txt>" >&2
    exit 1
fi

BASE_NAME="${INPUT_FILE%_clean.txt}"
BASE_NAME="${BASE_NAME%.txt}"

CLEANED_FILE="${BASE_NAME}_korjattu.txt"
SUMMARY_FILE="${BASE_NAME}_yhteenveto.md"
PDF_FILE="${BASE_NAME}_yhteenveto.pdf"

echo "================================================================="
echo "🤖 Ollama Post-Processing Pipeline"
echo "   Model:        $OLLAMA_MODEL"
echo "   Input:        $INPUT_FILE"
echo "   Clean text:   $CLEANED_FILE"
echo "   Summary:      $SUMMARY_FILE"
echo "   PDF:          $PDF_FILE"
echo "================================================================="

# --- Pass 1: Fix Speech Recognition Artefacts & Finnish Grammar ---
echo "==> [Pass 1/2] Korjataan puheentunnistusvirheet ja kielioppi ($OLLAMA_MODEL)..."

PROMPT_CLEANUP=$(cat <<'EOF'
Olet ammattitaitoinen suomen kielen ja teknisten tekstien oikolukija.
Alla on automaattisella puheentunnistuksella (Whisper) litteroitu luentoteksti, jossa on mukana diakuvaviittauksia muodossa:
![Dia (MM:SS)](slides/...)

Tehtäväsi:
1. Korjaa puheentunnistuksen virheet:
   - Väärin kuullut sanat ja foneettiset virheet
   - Yhdyssanavirheet ja puhekielen epäloogisuudet
   - Turhat täytesanat ja takeltelut (esim. "niinku", "tota noin"), kuitenkin säilyttäen puhujan asiasisällön ja tyylin
2. TÄRKEÄÄ: Säilytä KAIKKI diakuvaviittaukset (muodossa ![Dia...](...)) täsmälleen oikeilla paikoillaan omilla riveillään.
3. Älä keksi uutta asiaa äläkä poista asiaan kuuluvaa tietoa.
4. ÄLÄ lisää mitään tervehdystä, saatesanoja tai selityksiä. Tulosta VAIN korjattu teksti dioineen.

Luentoteksti ja diat:
EOF
)

(
    echo "$PROMPT_CLEANUP"
    echo ""
    cat "$INPUT_FILE"
) | ollama run "$OLLAMA_MODEL" --nowordwrap --think=false | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' > "$CLEANED_FILE"

echo "[+] Korjattu teksti tallennettu: $CLEANED_FILE"

# --- Pass 2: Generate Structured Markdown Synopsis ---
echo "==> [Pass 2/3] Luodaan jäsennelty luentoyhteenveto ($OLLAMA_MODEL)..."
RAW_SUMMARY="${BASE_NAME}_yhteenveto_raw.md"

PROMPT_SUMMARY=$(cat <<'EOF'
Olet yliopistotason opiskeluassistentti. Alla on siistitty ja korjattu luentotranskriptio sekä esityksen diojen kuvamerkinnät muodossa ![Dia](...).

Tehtäväsi:
Tee tekstistä selkeä, jäsennelty ja ammattimainen Markdown-opintoyhteenveto suomeksi (enintään 2-3 sivua).
Sijoita aiheeseen liittyvät diojen kuvamerkinnät luontevasti väliotsikoiden alle havainnollistamaan tekstiä.

Käytä vähintään seuraavaa rakennetta:
## Tiivistelmä
## Keskeiset käsitteet ja aiheet
## Tehtävät ja harjoitustyöt
## Arviointiperusteet ja vaatimukset
## Tärkeät päivämäärät ja deadlinet

Luentoteksti ja diat:
EOF
)

(
    echo "$PROMPT_SUMMARY"
    echo ""
    cat "$CLEANED_FILE"
) | ollama run "$OLLAMA_MODEL" --nowordwrap --think=false | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' > "$RAW_SUMMARY"

echo "[+] Yhteenvedon luonnos luotu: $RAW_SUMMARY"

# --- Pass 3: Polish & Review ---
echo "==> [Pass 3/3] Viimeistellään ja oikoluetaan yhteenveto ($OLLAMA_MODEL)..."

PROMPT_POLISH=$(cat <<'EOF'
Olet akateeminen kielenhuoltaja ja opiskelumateriaalien toimittaja.
Alla on luonnos luentoyhteenvedosta, jossa on mukana diakuvia muodossa ![Dia...](...).

Tehtäväsi:
1. Viimeistele teksti: poista toistot, korjaa lauserakenteet ja sanamuodot luontevaksi, huolitelluksi asiatyyliksi.
2. Varmista, että kurssin vaatimukset, tehtävänanto (sivumäärät, arviointiasteikko) ja aikataulut ovat selkeitä ja helppolukuisia (käytä selkeitä luettelomerkkejä ja lihavointeja).
3. Säilytä KAIKKI diakuvamerkinnät ![Dia...](...) paikoillaan.
4. ÄLÄ lisää mitään johdanto- tai lopetussanoja ('Tässä on korjattu versio...'). Tulosta suoraan valmis Markdown-dokumentti.

Luonnos:
EOF
)

(
    echo "$PROMPT_POLISH"
    echo ""
    cat "$RAW_SUMMARY"
) | ollama run "$OLLAMA_MODEL" --nowordwrap --think=false | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' > "$SUMMARY_FILE"

rm -f "$RAW_SUMMARY"
echo "[+] Viimeistelty yhteenveto valmis: $SUMMARY_FILE"

# --- Deduce Heading & Organize into Dedicated Lecture Folder ---
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

# Extract sequential number if BASE_NAME starts with digits
RUN_NUM=""
if [[ "$BASE_NAME" =~ ^([0-9]{2})_ ]]; then
    RUN_NUM="${BASH_REMATCH[1]}"
fi

if [[ -n "$DEDUCED_SLUG" ]]; then
    if [[ -n "$RUN_NUM" ]]; then
        TARGET_DIR="${RUN_NUM}_${DEDUCED_SLUG}"
    else
        TARGET_DIR="$DEDUCED_SLUG"
    fi
else
    TARGET_DIR="$BASE_NAME"
fi

echo "==> Siirretään luentomateriaalit omaan kansioonsa '$TARGET_DIR/'..."
mkdir -p "$TARGET_DIR"

# Move slides if present
if [[ -d "slides/${BASE_NAME}" ]]; then
    mkdir -p "$TARGET_DIR/slides"
    cp -r "slides/${BASE_NAME}"/* "$TARGET_DIR/slides/" 2>/dev/null || true
    rm -rf "slides/${BASE_NAME}"
    rmdir slides 2>/dev/null || true
fi

# Update slide image paths to relative 'slides/'
for txt in "$SUMMARY_FILE" "$CLEANED_FILE" "$INPUT_FILE"; do
    if [[ -f "$txt" ]]; then
        sed -i '' -E "s|slides/${BASE_NAME}/|slides/|g; s|slides/|slides/|g" "$txt" 2>/dev/null || true
    fi
done

# Move text files into target folder
NEW_SUMMARY_FILE="$TARGET_DIR/${TARGET_DIR}_yhteenveto.md"
mv "$SUMMARY_FILE" "$NEW_SUMMARY_FILE"
SUMMARY_FILE="$NEW_SUMMARY_FILE"

if [[ -f "$CLEANED_FILE" ]]; then
    mv "$CLEANED_FILE" "$TARGET_DIR/${TARGET_DIR}_korjattu.txt"
    CLEANED_FILE="$TARGET_DIR/${TARGET_DIR}_korjattu.txt"
fi

# Move any raw transcript or srt matching base name
for extra in "${BASE_NAME}.txt" "${BASE_NAME}_clean.txt" "${BASE_NAME}.srt" "${BASE_NAME}.mp4"; do
    if [[ -f "$extra" ]]; then
        EXT="${extra##*.}"
        SUF=""
        [[ "$extra" == *"_clean.txt" ]] && SUF="_clean"
        mv "$extra" "$TARGET_DIR/${TARGET_DIR}${SUF}.${EXT}"
    fi
done

PDF_FILE="$TARGET_DIR/${TARGET_DIR}_yhteenveto.pdf"

# --- PDF Generation ---
if [[ -f "$SCRIPT_DIR/md_to_pdf.py" ]]; then
    echo "==> [PDF] Muunnetaan tyylitellyksi PDF-dokumentiksi..."
    $PYTHON_EXEC "$SCRIPT_DIR/md_to_pdf.py" "$SUMMARY_FILE" -o "$PDF_FILE" || {
        echo "[!] Huom: PDF-muunnos ohitettiin tai epäonnistui."
    }
fi

echo ""
echo "================================================================="
echo "🎉 Valmis! Kaikki luentomateriaalit koottu kansioon:"
echo "   📁 $TARGET_DIR/"
echo "================================================================="
echo "  📝 Yhteenveto      : $SUMMARY_FILE"
if [[ -f "$CLEANED_FILE" ]]; then
    echo "  📄 Korjattu teksti : $CLEANED_FILE"
fi
if [[ -f "$PDF_FILE" ]]; then
    echo "  📑 PDF-dokumentti  : $PDF_FILE"
fi
if [[ -d "$TARGET_DIR/slides" ]]; then
    echo "  🖼️ Esityksen diat  : $TARGET_DIR/slides/"
fi
echo "================================================================="
