# 🎓 Lecture Ripper, Slide Extractor & Transcriber

An automated local pipeline for downloading streams, extracting slide keyframes, generating speech-to-text transcripts with **mlx-whisper** (Apple Silicon Metal GPU acceleration), and producing Markdown synopses with a local LLM via **Ollama**.

Optimized for **Apple Silicon (M1/M2/M3/M4)** via MLX Metal GPU and **AMD/Intel CPUs**.

---

## ✨ Features

- **🛡️ 100% Local & Private**: No data sent to third-party cloud APIs.
- **⚡ FFmpeg Speech Preprocessing**: Direct 16 kHz mono resampling, speech bandpass filtering (75 Hz–7.5 kHz), and speech volume leveling (`speechnorm`).
- **🖼️ Automated Slide Extraction**: Scene detection captures slide transitions and saves timestamped screenshots (`slides/01_lecture/slide_03m45s.jpg`).
- **🎯 Hallucination-Free Finnish Transcription**: Uses Silero Voice Activity Detection (VAD) and Finnish grammar conditioning.
- **📁 Self-Contained Lecture Folders**: Automatically deduces the lecture topic heading from the LLM summary (e.g. `03_kyberturvallisuuden_johtaminen/`) and packages all slides, transcripts, subtitles, video, and PDF into its own dedicated directory.
- **📝 Multi-Format Output**: Generates timestamped logs, clean text, SRT subtitles, and an AI course summary.
- **🔢 Auto-Sequential Numbering**: Automatically numbers lectures (`01_...`, `02_...`, `03_...`).

---

## 📋 Requirements

Ensure the following tools are installed on your machine:

- **ffmpeg** (`brew install ffmpeg` on macOS)
- **python3** (3.10+)
- **ollama** (optional, for LLM summary)

---

## 🚀 Quick Start

### Option A: Grab Video Directly from Browser Player (Easiest & Most Reliable)
When viewing an embedded lecture player (e.g. Kaltura in Moodle, Panopto):
1. Open Browser DevTools (**F12** or **Option+Cmd+I**) and click the **Network** tab.
2. Press **Play** on the video.
3. In Network tab filter by `m3u8` (or right-click any video stream / `.ts` segment request).
4. Select **Copy** -> **Copy as cURL**.
5. In your terminal, run:
   ```bash
   ./catch_stream.py -c --run-pipeline
   ```
   *(The `-c` flag reads the copied cURL command directly from your macOS clipboard, automatically resolves playlist URLs and headers, downloads the full `.mp4`, and kicks off the transcription and note-taking pipeline!)*

---

### Option B: Run on an Existing Local Video File
```bash
./rip-transcribe.sh lecture.mp4
```

### Option C: Re-run Only Summary & PDF on Existing Transcript
```bash
./rip-transcribe.sh --only-summary 01_02_luento_clean.txt
```

---

## 🛠️ CLI Options

```text
Usage: rip-transcribe.sh [OPTIONS] <SOURCE_URL_OR_FILE>

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
```

---

## 📁 Generated Artefacts

Running `./rip-transcribe.sh lecture.mp4` produces:

```text
├── 01_lecture_yhteenveto.md     # Markdown synopsis with embedded slide images
├── 01_lecture.txt               # Timestamped transcript log ([01:23 -> 01:45])
├── 01_lecture_clean.txt         # Clean text with slide markers
├── 01_lecture.srt               # Video subtitle track
└── slides/
    └── 01_lecture/              # Extracted slide keyframes
        ├── slide_00m00s.jpg
        ├── slide_03m45s.jpg
        └── ...
```

---

## 📄 License

MIT
