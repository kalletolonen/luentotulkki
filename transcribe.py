#!/usr/bin/env python3
"""
Enhanced Whisper Transcription Script with Apple MLX & Faster-Whisper Support
Optimized for Apple Silicon via mlx-whisper (Metal GPU), with automatic fallback,
hallucination suppression, multi-format outputs, and slide image alignment.
"""

import sys
import os
import re
import argparse
from pathlib import Path

# Mapping friendly model names to mlx-community Hugging Face repositories
MLX_MODEL_MAP = {
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "small": "mlx-community/whisper-small-mlx",
    "base": "mlx-community/whisper-base-mlx",
    "tiny": "mlx-community/whisper-tiny",
}

def format_timestamp(seconds: float) -> str:
    """Format seconds into HH:MM:SS or MM:SS."""
    hrs = int(seconds // 3600)
    mins = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    if hrs > 0:
        return f"{hrs:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"

def format_srt_timestamp(seconds: float) -> str:
    """Format seconds into SRT timestamp format: HH:MM:SS,mmm."""
    hrs = int(seconds // 3600)
    mins = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int((seconds - int(seconds)) * 1000)
    return f"{hrs:02d}:{mins:02d}:{secs:02d},{millis:03d}"

def load_slides_from_dir(slides_dir: str) -> list[tuple[float, str]]:
    """Loads slide images from directory and parses timestamps from filenames like slide_03m45s.jpg."""
    slides = []
    if not slides_dir or not os.path.isdir(slides_dir):
        return slides
    
    pattern = re.compile(r"slide_(\d+)m(\d+)s\.(jpg|jpeg|png)", re.IGNORECASE)
    for fname in sorted(os.listdir(slides_dir)):
        match = pattern.match(fname)
        if match:
            mins = int(match.group(1))
            secs = int(match.group(2))
            total_sec = float(mins * 60 + secs)
            rel_path = os.path.join(slides_dir, fname)
            slides.append((total_sec, rel_path))
            
    slides.sort(key=lambda x: x[0])
    return slides

def transcribe_mlx(input_path: str, model_name: str, language: str, prompt: str):
    """Transcribe using mlx-whisper (Apple Silicon Metal acceleration)."""
    import mlx_whisper

    model_repo = MLX_MODEL_MAP.get(model_name, model_name)
    print(f"[*] Transcribing with mlx-whisper on Apple Silicon GPU...", file=sys.stderr)
    print(f"[*] Model: {model_repo} (language: {language})", file=sys.stderr)

    result = mlx_whisper.transcribe(
        input_path,
        path_or_hf_repo=model_repo,
        language=language,
        initial_prompt=prompt,
        condition_on_previous_text=False,
        verbose=False,
    )

    raw_segments = result.get("segments", [])
    normalized_segments = []
    for s in raw_segments:
        normalized_segments.append({
            "start": float(s.get("start", 0.0)),
            "end": float(s.get("end", 0.0)),
            "text": s.get("text", "").strip()
        })
    return normalized_segments

def transcribe_faster_whisper(input_path: str, model_name: str, language: str, prompt: str,
                              device: str, compute_type: str, threads: int, no_vad: bool, beam_size: int):
    """Fallback: Transcribe using faster-whisper (CTranslate2)."""
    from faster_whisper import WhisperModel

    print(f"[*] Loading Faster-Whisper model '{model_name}' ({device} / {compute_type})...", file=sys.stderr)
    model = WhisperModel(
        model_name,
        device=device,
        compute_type=compute_type,
        cpu_threads=threads
    )

    print(f"[*] Transcribing audio (language: {language}, VAD: {not no_vad})...", file=sys.stderr)
    segments, info = model.transcribe(
        input_path,
        language=language,
        beam_size=beam_size,
        vad_filter=not no_vad,
        vad_parameters=dict(min_silence_duration_ms=500, speech_pad_ms=400) if not no_vad else None,
        initial_prompt=prompt,
        condition_on_previous_text=False,
        no_speech_threshold=0.6
    )

    normalized_segments = []
    for s in segments:
        normalized_segments.append({
            "start": float(s.start),
            "end": float(s.end),
            "text": s.text.strip()
        })
    return normalized_segments

def main():
    parser = argparse.ArgumentParser(
        description="Transcribe lecture audio/video with mlx-whisper (Apple Silicon) or faster-whisper."
    )
    parser.add_argument("input", help="Path to input audio/video file")
    parser.add_argument("-m", "--model", default="large-v3-turbo", help="Whisper model size (default: large-v3-turbo, e.g. large-v3, medium, small)")
    parser.add_argument("-l", "--language", default="fi", help="Language code (default: fi)")
    parser.add_argument("--backend", default="auto", choices=["auto", "mlx", "faster-whisper"], help="Whisper engine: auto, mlx, or faster-whisper")
    parser.add_argument("--device", default="cpu", choices=["cpu", "cuda", "auto"], help="Device for faster-whisper (default: cpu)")
    parser.add_argument("--compute-type", default="int8", help="Compute type for faster-whisper (default: int8)")
    parser.add_argument("--threads", type=int, default=4, help="CPU threads for faster-whisper (default: 4)")
    parser.add_argument("-o", "--output-prefix", default="transcript", help="Output file prefix (default: transcript)")
    parser.add_argument("--slides-dir", default=None, help="Directory containing timestamped slide images (e.g. slides/)")
    parser.add_argument("--prompt", default="Tämä on suomenkielinen yliopisto- tai ammattikorkeakoululuento ja opetusmateriaali.", help="Initial prompt context")
    parser.add_argument("--no-vad", action="store_true", help="Disable Voice Activity Detection in faster-whisper")
    parser.add_argument("--beam-size", type=int, default=5, help="Beam size for faster-whisper (default: 5)")

    args = parser.parse_args()

    input_path = args.input
    if not os.path.exists(input_path):
        sys.exit(f"Error: Input file not found: {input_path}")

    # Load slides if available
    slides = load_slides_from_dir(args.slides_dir) if args.slides_dir else []
    if slides:
        print(f"[*] Loaded {len(slides)} slide images from '{args.slides_dir}' to align with transcript.", file=sys.stderr)

    # Determine backend
    backend = args.backend
    if backend == "auto":
        try:
            import mlx_whisper
            backend = "mlx"
        except ImportError:
            backend = "faster-whisper"

    if backend == "mlx":
        try:
            segments = transcribe_mlx(
                input_path=input_path,
                model_name=args.model,
                language=args.language,
                prompt=args.prompt,
            )
        except Exception as e:
            print(f"[!] mlx-whisper failed: {e}. Falling back to faster-whisper...", file=sys.stderr)
            segments = transcribe_faster_whisper(
                input_path=input_path,
                model_name=args.model,
                language=args.language,
                prompt=args.prompt,
                device=args.device,
                compute_type=args.compute_type,
                threads=args.threads,
                no_vad=args.no_vad,
                beam_size=args.beam_size
            )
    else:
        segments = transcribe_faster_whisper(
            input_path=input_path,
            model_name=args.model,
            language=args.language,
            prompt=args.prompt,
            device=args.device,
            compute_type=args.compute_type,
            threads=args.threads,
            no_vad=args.no_vad,
            beam_size=args.beam_size
        )

    timestamped_lines = []
    clean_lines = []
    srt_blocks = []

    slide_idx = 0
    srt_idx = 1
    
    for seg in segments:
        text = seg["text"].strip()
        if not text:
            continue
        
        start = seg["start"]
        end = seg["end"]

        # Inject any slide that occurred before or at this segment
        while slide_idx < len(slides) and slides[slide_idx][0] <= start:
            slide_ts, slide_path = slides[slide_idx]
            slide_tag = f"\n![Dia ({format_timestamp(slide_ts)})]({slide_path})\n"
            timestamped_lines.append(slide_tag)
            clean_lines.append(slide_tag)
            print(slide_tag)
            slide_idx += 1

        # 1. Timestamped log
        t_start = format_timestamp(start)
        t_end = format_timestamp(end)
        line = f"[{t_start} -> {t_end}] {text}"
        print(line)  # live stdout
        sys.stdout.flush()
        timestamped_lines.append(line)
        
        # 2. Clean text for LLM synopsis
        clean_lines.append(text)

        # 3. SubRip format (SRT)
        srt_blocks.append(
            f"{srt_idx}\n"
            f"{format_srt_timestamp(start)} --> {format_srt_timestamp(end)}\n"
            f"{text}\n"
        )
        srt_idx += 1

    # Append any remaining slides that occurred near the end
    while slide_idx < len(slides):
        slide_ts, slide_path = slides[slide_idx]
        slide_tag = f"\n![Dia ({format_timestamp(slide_ts)})]({slide_path})\n"
        timestamped_lines.append(slide_tag)
        clean_lines.append(slide_tag)
        slide_idx += 1

    prefix = args.output_prefix
    
    # Write timestamped transcript
    raw_path = f"{prefix}.txt"
    with open(raw_path, "w", encoding="utf-8") as f:
        f.write("\n".join(timestamped_lines) + "\n")

    # Write clean text transcript (optimal for LLM feeding)
    clean_path = f"{prefix}_clean.txt"
    with open(clean_path, "w", encoding="utf-8") as f:
        f.write("\n\n".join(clean_lines) + "\n")

    # Write SRT subtitles
    srt_path = f"{prefix}.srt"
    with open(srt_path, "w", encoding="utf-8") as f:
        f.write("\n".join(srt_blocks) + "\n")

    # Print explicit completion cues
    print(f"\nFinished! Saved to {raw_path}")
    print(f"Finished! Saved clean text to {clean_path}")
    print(f"Finished! Saved subtitles to {srt_path}")

if __name__ == "__main__":
    main()
