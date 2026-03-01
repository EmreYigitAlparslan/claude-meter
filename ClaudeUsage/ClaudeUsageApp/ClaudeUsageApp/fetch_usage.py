#!/usr/bin/env python3
"""
Fetches Claude Code /usage output via PTY.
Usage: python3 fetch_usage.py /path/to/claude
"""
import pty, os, sys, time, threading, signal

def main():
    claude = sys.argv[1] if len(sys.argv) > 1 else "claude"

    # Continuously collect all output in a thread
    all_output = []
    stop_reading = threading.Event()

    master_fd, slave_fd = pty.openpty()

    # Set terminal size (80x24) so TUI renders properly
    import struct, fcntl, termios
    winsize = struct.pack("HHHH", 24, 80, 0, 0)
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsize)

    # Extend PATH so node/claude can be found from app bundle context
    path_extras = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]
    current_path = os.environ.get("PATH", "")
    os.environ["PATH"] = ":".join(path_extras) + (":" + current_path if current_path else "")

    pid = os.fork()
    if pid == 0:
        # Child: become claude
        os.close(master_fd)
        os.setsid()
        try:
            fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        except Exception:
            pass
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        os.close(slave_fd)
        # Use home dir as cwd — avoids "trust this folder?" for unknown dirs
        os.chdir(os.path.expanduser("~"))
        os.execve(claude, [claude], os.environ)
        sys.exit(1)

    os.close(slave_fd)

    def read_loop():
        while not stop_reading.is_set():
            try:
                import select
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if r:
                    chunk = os.read(master_fd, 4096)
                    all_output.append(chunk)
            except OSError:
                break

    reader = threading.Thread(target=read_loop, daemon=True)
    reader.start()

    def is_alive():
        try:
            result = os.waitpid(pid, os.WNOHANG)
            return result == (0, 0)
        except ChildProcessError:
            return False

    def send(data, delay_after=0.1):
        try:
            os.write(master_fd, data)
        except OSError:
            pass  # child may have exited
        time.sleep(delay_after)

    # Wait for claude to start, check if it's still alive
    for _ in range(12):  # wait up to 6s, checking every 0.5s
        time.sleep(0.5)
        if not is_alive():
            sys.stderr.write("Claude exited early\n")
            combined = b"".join(all_output)
            with open("/tmp/claude_usage_raw.bin", "wb") as f:
                f.write(combined)
            sys.stdout.buffer.write(combined)
            sys.stdout.flush()
            return

    # Handle "trust this folder?" dialog — send "1" + Enter to confirm
    # This is harmless if the dialog doesn't appear (home dir is already trusted)
    current = b"".join(all_output).decode("utf-8", errors="replace")
    if "trust" in current.lower():
        send(b"1\r", delay_after=2)

    # Type /usage char by char
    for ch in b"/usage":
        send(bytes([ch]), delay_after=0.05)

    # Press Enter (just \r, no \n — \n would dismiss TUI immediately)
    send(b"\r", delay_after=6)  # wait 6s for TUI to fully render

    # Send Escape to dismiss TUI
    send(b"\x1b", delay_after=1)

    # Exit claude
    send(b"/exit\r", delay_after=1)

    # Stop reading and clean up
    stop_reading.set()
    reader.join(timeout=2)

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except Exception:
        pass
    os.close(master_fd)

    combined = b"".join(all_output)

    # Strip ANSI codes
    import re
    text = combined.decode("utf-8", errors="replace")
    text = re.sub(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])', '', text)
    # Remove all whitespace so split words rejoin: "Curre t session" -> "Curretsession"
    text_nospace = re.sub(r'\s+', '', text).lower()

    def find_percent(after_keyword):
        idx = text_nospace.find(after_keyword)
        if idx == -1:
            return None
        segment = text_nospace[idx:idx+50]
        m = re.search(r'(\d+)%', segment)
        return int(m.group(1)) if m else None

    def find_resets(after_keyword):
        # Search in original text (with spaces) for reset times
        lower = text.lower()
        idx = lower.find(after_keyword.replace(" ", ""))
        # fallback: search with spaces stripped
        text_lower_nospace = text_nospace
        ki = text_lower_nospace.find(after_keyword.replace(" ", ""))
        if ki == -1:
            return None
        # Find "resets" after keyword in nospace text
        ri = text_lower_nospace.find("resets", ki)
        if ri == -1:
            return None
        # Get a slice around "resets" from original text and find the reset line
        # Map nospace index back to original is complex; just search original text
        m = re.search(r'[Rr]esets\s+\S+[^\n]*', text[ri:ri+200] if ri < len(text) else "")
        return m.group(0).strip() if m else None

    # Find all percentages in the nospace text in order
    # The usage TUI always shows: session % first, then weekly %
    # Skip any % that appear before the usage panel (e.g. in autocomplete hints)
    # Anchor on "session" appearing before first %, "week" before second
    all_pcts = [(m.start(), int(m.group(1))) for m in re.finditer(r'(\d+)%', text_nospace)]

    # Find index of first "session"-like pattern and "week"-like pattern
    session_idx = next((i for i, c in enumerate(text_nospace) if text_nospace[i:i+7] in ('session', 'currents', 'curretsess'[:7])), -1)
    # More robust: find "sess" substring
    sess_pos = text_nospace.find("sess")
    week_pos = text_nospace.find("week", sess_pos if sess_pos != -1 else 0)

    session_pct = next((v for pos, v in all_pcts if sess_pos != -1 and pos > sess_pos), None)
    weekly_pct = next((v for pos, v in all_pcts if week_pos != -1 and pos > week_pos), None)

    # Find resets — look for time/date pattern after keyword in nospace text
    # "Resets" may be mangled in partial TUI updates, so search for time patterns directly
    def find_resets_simple(after_nospace):
        ki = text_nospace.find(after_nospace)
        if ki == -1:
            return None
        segment = text_nospace[ki:ki+200]
        # Match time like "8pm", "7am", or date like "Mar6"
        m = re.search(r'(\d{1,2}[ap]m)', segment)
        if m:
            # Try to get a richer reset string from original text
            time_str = m.group(1)
            om = re.search(re.escape(time_str) + r'[^\n\x1B]*', text)
            if om:
                return "Resets " + re.sub(r'\x1B[^a-zA-Z]*[a-zA-Z]', '', om.group(0)).strip()
            return "Resets " + time_str
        # Try date pattern like "Mar6,7am"
        m = re.search(r'([A-Z][a-z]{2}\d)', segment)
        if m:
            return "Resets " + m.group(1)
        return None

    import json
    result = {
        "session": session_pct,
        "weekly": weekly_pct,
        "sessionResets": find_resets_simple("sess"),
        "weeklyResets": find_resets_simple("currentweek"),
    }
    print(json.dumps(result))

main()
