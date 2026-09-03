#!/usr/bin/env python3
"""
catch_stream.py - Automated Stream & cURL Resolver for Lecture Videos
Extracts stream URLs and authentication headers from browser DevTools (cURL commands or URLs),
automatically resolves HLS playlists from segments (e.g. Kaltura, Panopto, generic HLS),
and downloads clean local MP4 files ready for transcription.
"""

import sys
import os
import re
import shlex
import shutil
import argparse
import subprocess
from urllib.parse import urlparse, urlunparse

def get_clipboard_content() -> str:
    """Read clipboard on macOS via pbpaste."""
    if shutil.which("pbpaste"):
        try:
            res = subprocess.run(["pbpaste"], capture_output=True, text=True, check=True)
            return res.stdout.strip()
        except Exception:
            return ""
    return ""

def parse_curl(raw_input: str) -> tuple[str, dict[str, str]]:
    """
    Parse a curl command or raw URL string and extract the target URL and HTTP headers.
    """
    raw_input = raw_input.strip()
    if not raw_input:
        raise ValueError("Empty input provided.")

    # If it's just a raw URL, return it directly
    if raw_input.startswith("http://") or raw_input.startswith("https://"):
        return raw_input, {}

    try:
        tokens = shlex.split(raw_input)
    except Exception:
        # Fallback to simple split if shlex fails on malformed quotes
        tokens = raw_input.split()

    url = ""
    headers = {}
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "curl":
            i += 1
            continue
        elif token in ("-H", "--header") and i + 1 < len(tokens):
            header_str = tokens[i + 1]
            if ":" in header_str:
                k, v = header_str.split(":", 1)
                headers[k.strip()] = v.strip()
            i += 2
        elif token in ("-A", "--user-agent") and i + 1 < len(tokens):
            headers["User-Agent"] = tokens[i + 1].strip()
            i += 2
        elif token in ("-e", "--referer") and i + 1 < len(tokens):
            headers["Referer"] = tokens[i + 1].strip()
            i += 2
        elif token.startswith("http://") or token.startswith("https://"):
            url = token
            i += 1
        elif token.startswith("'http://") or token.startswith("'https://") or token.startswith('"http'):
            url = token.strip("'\"")
            i += 1
        else:
            i += 1

    if not url:
        # Search via regex for any http/https URL in the string
        match = re.search(r'https?://[^\s\'"]+', raw_input)
        if match:
            url = match.group(0)
        else:
            raise ValueError("Could not find a valid HTTP/HTTPS URL in the provided input.")

    return url, headers

def resolve_stream_url(url: str) -> str:
    """
    Converts segment/chunk URLs into master/index playlists:
    - Kaltura: .../serveFlavor/.../name/a.mp4/seg-1-v1-a1.ts -> .../index.m3u8
    - Generic: .../seg-*.ts -> .../index.m3u8
    """
    parsed = urlparse(url)
    path = parsed.path

    # Kaltura HLS segment pattern: /name/a.mp4/seg-\d+-.*\.ts
    if "kaltura" in parsed.netloc or "serveFlavor" in path:
        kaltura_seg_match = re.sub(r'/seg-[^/]+\.ts$', '/index.m3u8', path)
        if kaltura_seg_match != path:
            return urlunparse(parsed._replace(path=kaltura_seg_match))

    # Generic .ts / .m4s / .mp4 fragment pattern
    if re.search(r'/(seg|segment|chunk)[^/]*\.(ts|m4s)$', path, re.IGNORECASE):
        # Try replacing the segment file with index.m3u8
        new_path = re.sub(r'/[^/]+\.(ts|m4s)$', '/index.m3u8', path, flags=re.IGNORECASE)
        return urlunparse(parsed._replace(path=new_path))

    return url

def format_ffmpeg_headers(headers: dict[str, str]) -> tuple[str, str]:
    """
    Format headers for ffmpeg:
    - Extracts User-Agent separately.
    - Joins other relevant headers with CRLF.
    """
    user_agent = headers.get("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:153.0) Gecko/20100101 Firefox/153.0")
    
    important_headers = []
    # Relevant headers for auth and CDN access
    for key in ["Referer", "Origin", "Cookie", "Authorization", "Sec-Fetch-Site", "Sec-Fetch-Mode"]:
        if key in headers:
            important_headers.append(f"{key}: {headers[key]}")

    crlf_headers = "\r\n".join(important_headers) + ("\r\n" if important_headers else "")
    return user_agent, crlf_headers

def find_next_lecture_filename() -> str:
    """Auto-detect next sequential lecture filename: 01_..., 02_..., etc."""
    next_num = 1
    for f in os.listdir("."):
        m = re.match(r'^(\d{2})_.*', f)
        if m:
            num = int(m.group(1))
            if num >= next_num:
                next_num = num + 1
    return f"{next_num:02d}_luento.mp4"

def main():
    parser = argparse.ArgumentParser(
        description="Extract video streams from DevTools cURL / URLs and download as MP4."
    )
    parser.add_argument("input", nargs="?", help="cURL command string or URL copied from browser DevTools")
    parser.add_argument("-c", "--clipboard", action="store_true", help="Read cURL command or URL from system clipboard (macOS)")
    parser.add_argument("-o", "--output", help="Output MP4 filename (default: auto-detected sequential e.g. 02_luento.mp4)")
    parser.add_argument("--run-pipeline", action="store_true", help="Automatically run ./rip-transcribe.sh after download")
    args = parser.parse_args()

    raw_input = args.input or ""
    if not raw_input and (args.clipboard or not sys.stdin.isatty()):
        if args.clipboard:
            raw_input = get_clipboard_content()
        elif not sys.stdin.isatty():
            raw_input = sys.stdin.read().strip()

    if not raw_input:
        # Prompt user interactively
        print("[*] Paste your cURL command or video URL from the browser Network tab:")
        print("    (Tip: In DevTools -> Network, right-click the video request -> Copy -> Copy as cURL)")
        try:
            raw_input = input("> ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nAborted.")
            sys.exit(0)

    try:
        original_url, headers = parse_curl(raw_input)
    except Exception as e:
        print(f"[!] Error parsing input: {e}", file=sys.stderr)
        sys.exit(1)

    stream_url = resolve_stream_url(original_url)
    user_agent, crlf_headers = format_ffmpeg_headers(headers)

    output_file = args.output or find_next_lecture_filename()

    print("\n=================================================================")
    print("🎬 Video Stream Detected")
    print(f"  Source URL : {original_url}")
    if stream_url != original_url:
        print(f"  Resolved   : {stream_url} (auto-converted segment -> playlist)")
    print(f"  Headers    : {len(headers)} detected ({', '.join(headers.keys()) if headers else 'none'})")
    print(f"  Target MP4 : {output_file}")
    print("=================================================================\n")

    # Build ffmpeg download command
    cmd = ["ffmpeg", "-y", "-nostdin", "-loglevel", "info"]
    if user_agent:
        cmd.extend(["-user_agent", user_agent])
    if crlf_headers:
        cmd.extend(["-headers", crlf_headers])

    cmd.extend([
        "-reconnect", "1",
        "-reconnect_at_eof", "1",
        "-reconnect_streamed", "1",
        "-reconnect_delay_max", "5",
        "-i", stream_url,
        "-c", "copy",
        "-bsf:a", "aac_adtstoasc",
        output_file
    ])

    print("[*] Downloading video with FFmpeg...")
    try:
        proc = subprocess.run(cmd)
        if proc.returncode != 0:
            print(f"[!] Download failed with exit code {proc.returncode}", file=sys.stderr)
            sys.exit(proc.returncode)
    except KeyboardInterrupt:
        print("\n[!] Download interrupted by user.")
        sys.exit(130)

    if os.path.exists(output_file) and os.path.getsize(output_file) > 0:
        size_mb = os.path.getsize(output_file) / (1024 * 1024)
        print(f"\n[+] Successfully saved: {output_file} ({size_mb:.1f} MB)")
        
        if args.run_pipeline:
            print(f"[*] Triggering ./rip-transcribe.sh {output_file} ...")
            subprocess.run(["./rip-transcribe.sh", output_file])
        else:
            print(f"\n👉 Next step: Run the notes pipeline on your new video:")
            print(f"   ./rip-transcribe.sh {output_file}\n")
    else:
        print("[!] Error: Downloaded file is empty or missing.", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
