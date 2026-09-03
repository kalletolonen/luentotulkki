#!/usr/bin/env python3
"""
Markdown to PDF Converter & Cleaner
Cleans LLM scratchpad thoughts and ANSI codes, formats slide images,
and renders a clean vector PDF using headless Chrome/Chromium/Brave/Edge or WeasyPrint.
"""

import sys
import os
import re
import argparse
import subprocess
import shutil
from pathlib import Path

def clean_llm_markdown(text: str) -> str:
    """Strips ANSI escape codes, <think> tags, and 'Thinking...' preamble."""
    # 1. Remove ANSI escape sequences
    ansi_regex = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\([a-zA-Z]|\x1b\)')
    text = ansi_regex.sub('', text)
    
    # 2. Remove <think>...</think> blocks
    text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL)
    
    # 3. Remove 'Thinking... ...done thinking.' preamble
    text = re.sub(r'Thinking\b.*?\.\.\.done thinking\.', '', text, flags=re.DOTALL | re.IGNORECASE)
    
    # 4. If text still starts with preamble before the first header, trim to first header
    match = re.search(r'^(#+\s+.+)$', text, flags=re.MULTILINE)
    if match and match.start() > 0:
        preamble = text[:match.start()].strip()
        # If preamble doesn't look like actual content (e.g. prompt reflection)
        if "The user wants" in preamble or "Let me structure" in preamble or "Thinking..." in preamble:
            text = text[match.start():]
            
    return text.strip()

def markdown_to_html(md_text: str, title: str = "Luentotiivistelmä", base_dir: str = ".") -> str:
    """Converts markdown text to standalone HTML with clean print styling."""
    try:
        import markdown
        html_body = markdown.markdown(md_text, extensions=['extra', 'tables', 'fenced_code'])
    except ImportError:
        # Fallback basic parser if markdown library is missing
        lines = []
        in_p = False
        for line in md_text.splitlines():
            line_str = line.strip()
            if line_str.startswith("### "):
                if in_p: lines.append("</p>"); in_p = False
                lines.append(f"<h3>{line_str[4:]}</h3>")
            elif line_str.startswith("## "):
                if in_p: lines.append("</p>"); in_p = False
                lines.append(f"<h2>{line_str[3:]}</h2>")
            elif line_str.startswith("# "):
                if in_p: lines.append("</p>"); in_p = False
                lines.append(f"<h1>{line_str[2:]}</h1>")
            elif line_str.startswith("!["):
                if in_p: lines.append("</p>"); in_p = False
                # parse image tag ![alt](url)
                m = re.match(r'!\[(.*?)\]\((.*?)\)', line_str)
                if m:
                    lines.append(f'<figure><img src="{m.group(2)}" alt="{m.group(1)}"><figcaption>{m.group(1)}</figcaption></figure>')
            elif line_str.startswith("- ") or line_str.startswith("* "):
                if in_p: lines.append("</p>"); in_p = False
                lines.append(f"<li>{line_str[2:]}</li>")
            elif not line_str:
                if in_p: lines.append("</p>"); in_p = False
            else:
                if not in_p:
                    lines.append("<p>")
                    in_p = True
                # bold
                line_fmt = re.sub(r'\*\*(.*?)\*\*', r'<strong>\1</strong>', line_str)
                lines.append(line_fmt)
        if in_p: lines.append("</p>")
        html_body = "\n".join(lines)

    html_template = f"""<!DOCTYPE html>
<html lang="fi">
<head>
<meta charset="utf-8">
<title>{title}</title>
<base href="{os.path.abspath(base_dir)}/">
<style>
  @page {{
    size: A4;
    margin: 20mm 15mm;
  }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    color: #1f2328;
    line-height: 1.6;
    max-width: 800px;
    margin: 0 auto;
    padding: 20px;
    font-size: 14px;
  }}
  h1 {{ font-size: 24px; border-bottom: 2px solid #eaecef; padding-bottom: 8px; margin-top: 24px; color: #0969da; }}
  h2 {{ font-size: 18px; border-bottom: 1px solid #eaecef; padding-bottom: 6px; margin-top: 20px; color: #1f2328; page-break-after: avoid; }}
  h3 {{ font-size: 15px; margin-top: 16px; color: #24292f; page-break-after: avoid; }}
  p, ul, ol {{ margin-bottom: 12px; }}
  li {{ margin-bottom: 4px; }}
  strong {{ color: #000; }}
  
  img {{
    max-width: 95%;
    max-height: 380px;
    height: auto;
    display: block;
    margin: 12px auto;
    border-radius: 6px;
    box-shadow: 0 2px 6px rgba(0,0,0,0.12);
    border: 1px solid #d0d7de;
    page-break-inside: avoid;
  }}
  figure {{
    margin: 16px 0;
    text-align: center;
    page-break-inside: avoid;
  }}
  figcaption {{
    font-size: 12px;
    color: #57606a;
    margin-top: 4px;
  }}
  pre, code {{
    background-color: #f6f8fa;
    border-radius: 4px;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 12px;
  }}
  code {{ padding: 2px 5px; }}
  pre {{ padding: 12px; overflow-x: auto; }}
  blockquote {{
    border-left: 4px solid #d0d7de;
    color: #57606a;
    padding-left: 12px;
    margin: 12px 0;
  }}
  hr {{
    height: 1px;
    background-color: #d0d7de;
    border: none;
    margin: 20px 0;
  }}
</style>
</head>
<body>
{html_body}
</body>
</html>"""
    return html_template

def find_browser_executable() -> str | None:
    """Looks for Chrome, Chromium, Brave, or Edge binaries across system and user folders."""
    candidates = [
        # macOS system paths
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        # macOS user paths (~/Applications/...)
        os.path.expanduser("~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        os.path.expanduser("~/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
        os.path.expanduser("~/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        # Linux / CLI paths
        shutil.which("google-chrome"),
        shutil.which("google-chrome-stable"),
        shutil.which("chromium"),
        shutil.which("chromium-browser"),
        shutil.which("brave-browser"),
        shutil.which("edge"),
    ]
    for path in candidates:
        if path and os.path.exists(path):
            return path

    # macOS Spotlight bundle lookup fallback
    if sys.platform == "darwin":
        for bundle_id in ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"]:
            try:
                res = subprocess.check_output(["mdfind", f"kMDItemCFBundleIdentifier == '{bundle_id}'"], text=True).strip()
                if res:
                    app_path = res.splitlines()[0]
                    bin_name = "Google Chrome" if "Chrome" in bundle_id else ("Brave Browser" if "brave" in bundle_id else "Microsoft Edge")
                    full_bin = os.path.join(app_path, "Contents", "MacOS", bin_name)
                    if os.path.exists(full_bin):
                        return full_bin
            except Exception:
                pass

    return None

def convert_html_to_pdf(html_path: str, pdf_path: str) -> bool:
    """Renders HTML to PDF using headless browser or WeasyPrint."""
    abs_html = os.path.abspath(html_path)
    abs_pdf = os.path.abspath(pdf_path)

    # 1. Try Headless Browser (Fastest, highest fidelity)
    browser = find_browser_executable()
    if browser:
        # First attempt: Direct modern headless print (fastest, avoids socket deadlock)
        cmd_direct = [
            browser,
            "--headless=new",
            "--no-pdf-header-footer",
            f"--print-to-pdf={abs_pdf}",
            f"file://{abs_html}"
        ]
        try:
            subprocess.run(cmd_direct, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15)
            if os.path.exists(abs_pdf) and os.path.getsize(abs_pdf) > 0:
                return True
        except Exception as e:
            print(f"[*] Direct browser print notice: {e}", file=sys.stderr)

        # Second attempt: Fallback with isolated user-data-dir
        import tempfile
        for headless_flag in ["--headless=new", "--headless"]:
            user_data_dir = tempfile.mkdtemp(prefix="chrome_headless_")
            cmd = [
                browser,
                headless_flag,
                f"--user-data-dir={user_data_dir}",
                "--no-pdf-header-footer",
                f"--print-to-pdf={abs_pdf}",
                f"file://{abs_html}"
            ]
            try:
                subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15)
                shutil.rmtree(user_data_dir, ignore_errors=True)
                if os.path.exists(abs_pdf) and os.path.getsize(abs_pdf) > 0:
                    return True
            except Exception as e:
                shutil.rmtree(user_data_dir, ignore_errors=True)

    # 2. Try WeasyPrint fallback
    try:
        import weasyprint
        weasyprint.HTML(filename=html_path).write_pdf(pdf_path)
        return True
    except Exception:
        pass

    # 3. Try wkhtmltopdf fallback
    if shutil.which("wkhtmltopdf"):
        try:
            subprocess.run(["wkhtmltopdf", "--enable-local-file-access", html_path, pdf_path], 
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            return True
        except Exception:
            pass

    return False

def main():
    parser = argparse.ArgumentParser(description="Convert Markdown summary to clean PDF.")
    parser.add_argument("input_md", help="Input Markdown file (e.g. 01_lecture_yhteenveto.md)")
    parser.add_argument("-o", "--output-pdf", default=None, help="Output PDF file path")
    parser.add_argument("--clean-md-inplace", action="store_true", default=True, help="Strip LLM thinking tags in the MD file")

    args = parser.parse_args()
    
    input_path = args.input_md
    if not os.path.exists(input_path):
        sys.exit(f"Error: File not found: {input_path}")
        
    pdf_path = args.output_pdf
    if not pdf_path:
        pdf_path = str(Path(input_path).with_suffix(".pdf"))
        
    html_path = str(Path(input_path).with_suffix(".html"))

    with open(input_path, "r", encoding="utf-8") as f:
        raw_text = f.read()

    cleaned_text = clean_llm_markdown(raw_text)

    # Overwrite cleaned markdown if requested
    if args.clean_md_inplace and cleaned_text != raw_text:
        with open(input_path, "w", encoding="utf-8") as f:
            f.write(cleaned_text + "\n")
        print(f"[*] Cleaned LLM preamble tags from '{input_path}'", file=sys.stderr)

    base_dir = os.path.dirname(os.path.abspath(input_path)) or "."
    doc_title = Path(input_path).stem.replace("_", " ").title()
    html_content = markdown_to_html(cleaned_text, title=doc_title, base_dir=base_dir)

    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_content)

    success = convert_html_to_pdf(html_path, pdf_path)
    
    # Clean up intermediate html
    if success and os.path.exists(html_path):
        os.remove(html_path)
        print(f"[+] Rendered PDF: {pdf_path}", file=sys.stderr)
    elif not success:
        print(f"[!] Warning: Could not render PDF automatically. Kept styled HTML at '{html_path}' (open and print to PDF).", file=sys.stderr)

if __name__ == "__main__":
    main()
