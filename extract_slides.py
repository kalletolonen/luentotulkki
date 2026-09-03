#!/usr/bin/env python3
"""
Lecture Slide Extractor
Extracts unique presentation slides and timestamps from lecture video files
using FFmpeg scene detection and perceptual deduplication.
"""

import sys
import os
import re
import argparse
import subprocess
from pathlib import Path

def parse_time_to_seconds(time_str: str) -> float:
    """Parse time formatted as HH:MM:SS or SS.ms to seconds."""
    parts = time_str.split(":")
    if len(parts) == 3:
        return float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
    elif len(parts) == 2:
        return float(parts[0]) * 60 + float(parts[1])
    return float(parts[0])

def format_slide_name(seconds: float) -> str:
    """Format seconds into slide_00m15s.jpg format."""
    mins = int(seconds // 60)
    secs = int(seconds % 60)
    return f"slide_{mins:02d}m{secs:02d}s.jpg"

def detect_slide_timestamps(video_path: str, scene_threshold: float = 0.15, min_interval: float = 5.0) -> list[float]:
    """
    Run FFmpeg scene filter to find timestamps where visual content changes significantly.
    """
    print(f"[*] Analyzing video for slide transitions (threshold={scene_threshold})...", file=sys.stderr)
    
    cmd = [
        "ffmpeg",
        "-nostdin",
        "-loglevel", "info",
        "-i", video_path,
        "-vf", f"select='gt(scene,{scene_threshold})+eq(n,0)',showinfo",
        "-f", "null",
        "-"
    ]
    
    proc = subprocess.Popen(cmd, stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True, errors="replace")
    
    timestamps = [0.0]  # Always include initial slide
    pts_regex = re.compile(r"pts_time:\s*([\d\.]+)")
    
    _, stderr = proc.communicate()
    for match in pts_regex.finditer(stderr):
        pts = float(match.group(1))
        # Enforce minimum interval between slides to avoid duplicate animation frames
        if pts - timestamps[-1] >= min_interval:
            timestamps.append(pts)
            
    return sorted(list(set(timestamps)))

def extract_slide_images(video_path: str, timestamps: list[float], output_dir: str = "slides") -> list[dict]:
    """
    Extract high-quality JPEG images for each detected slide timestamp.
    """
    os.makedirs(output_dir, exist_ok=True)
    slides_info = []
    
    print(f"[*] Extracting {len(timestamps)} slide images to '{output_dir}/'...", file=sys.stderr)
    
    for i, ts in enumerate(timestamps):
        filename = format_slide_name(ts)
        out_path = os.path.join(output_dir, filename)
        
        # Extract 1 frame at exact timestamp using fast seek
        cmd = [
            "ffmpeg",
            "-y",
            "-nostdin",
            "-loglevel", "error",
            "-ss", f"{ts:.3f}",
            "-i", video_path,
            "-vframes", "1",
            "-q:v", "2",
            out_path
        ]
        
        subprocess.run(cmd, check=True)
        mins = int(ts // 60)
        secs = int(ts % 60)
        time_label = f"{mins:02d}:{secs:02d}"
        
        slides_info.append({
            "index": i + 1,
            "timestamp": ts,
            "time_str": time_label,
            "filename": filename,
            "path": out_path,
            "markdown": f"![Dia {time_label}]({out_path})"
        })
        
    return slides_info

def main():
    parser = argparse.ArgumentParser(description="Extract slide keyframes from lecture video.")
    parser.add_argument("video", help="Path to input video file")
    parser.add_argument("-o", "--output-dir", default="slides", help="Output directory for slides (default: slides)")
    parser.add_argument("-t", "--threshold", type=float, default=0.15, help="Scene detection threshold (0.05-0.4, default: 0.15)")
    parser.add_argument("-i", "--min-interval", type=float, default=6.0, help="Minimum seconds between slides (default: 6.0)")

    args = parser.parse_args()

    if not os.path.exists(args.video) and not args.video.startswith(("http://", "https://")):
        sys.exit(f"Error: Video file not found: {args.video}")

    timestamps = detect_slide_timestamps(args.video, scene_threshold=args.threshold, min_interval=args.min_interval)
    slides = extract_slide_images(args.video, timestamps, output_dir=args.output_dir)

    print(f"\n[+] Extracted {len(slides)} slides into '{args.output_dir}/':", file=sys.stderr)
    for s in slides:
        print(f"  - [{s['time_str']}] {s['path']}")

if __name__ == "__main__":
    main()
