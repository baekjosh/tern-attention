#!/usr/bin/env python3
"""SYNTHETIC Tern protocol emitter; not OMP, an LLM, or runtime proof.

Run with Python 3 in a parent-owned native agent block, not a user shell/pane.
Type one command and Enter: working, waiting_input (or ask), idle (or done),
failed, status, exit (or quit), exit-failed. Ctrl-C/Ctrl-D also exit. The ask
button consumes a real TSP action and returns to idle; merely focusing does not.
No files, network, subprocesses, settings, or other panes are accessed.

Readiness is a successful TSP hello plus the READY view; the displayed ack is
only a received frame acknowledgement, never an agent-state assertion. Parent
must independently inspect native agents/events and exercise real pointer input.

Signal authority:
- https://docs.stencil.so/tern/reference/api-window.md#agent-cx ties native
  working/idle to OSC 9;4 and waiting_input to paused progress/an ask overlay.
- https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC defines
  OSC 9;4 states 0=clear, 2=error, 3=indeterminate, 4=paused, with ST endings.
- https://docs.stencil.so/tern/protocol/{handshake,transport,surfaces,input,
  documents,operations}.md define hello, frames, actions, acks and close/drain.
- https://github.com/stencil-hq/tern-sdk/blob/main/python/examples/ask.py and
  chat.py illustrate native buttons and inline main/dock/editor regions.
- Shipped tern.d.luau AgentBlock/AgentStateEvent expose idle, working,
  waiting_input, exited; AgentFinishedEvent exposes done, failed, exited, closed.

Proof gaps: the published TSP/AgentCx contract does not specify a direct
agent_finished result-emission verb. 'failed' emits documented ERROR PROGRESS,
not a forged failed event; 'done' clears progress, not a claimed task success.
Native failed/done mapping must be observed by the parent. A nonzero process
exit is an actual exit, NOT evidence of a failed turn. Closed requires parent
closing this owned block. No startup/delivery-error injection is provided.
"""

import json
import os
import select
import signal
import sys
import termios
import time
import tty


TITLE = "SYNTHETIC Attention protocol fixture"
SURFACE = "attention-synthetic-fixture"
ST = b"\x1b\\"
HELP = "working | waiting_input/ask | idle/done | failed | status | exit | exit-failed"


def output(data):
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def tsp(verb, body):
    output(b"\x1b_tsp;" + verb.encode("ascii") + b";"
           + json.dumps(body, ensure_ascii=True, separators=(",", ":")).encode("ascii") + ST)


def node(identity, kind, props=None, children=None):
    return {"id": identity, "k": kind, "p": props or {}, "c": children or []}


class Fixture:
    def __init__(self):
        self.buffer = bytearray()
        self.draft = ""
        self.hello = None
        self.open = False
        self.sequence = 0
        self.ack = 0
        self.dirty = True
        self.waiting = False
        self.clicks = 0
        self.message = "READY: synthetic emitter; native state not inspected"
        self.exit_code = None
        self.pasting = False
        self.rejected = False

    def command(self, text):
        command = text.strip().lower()
        if not command:
            return
        if command in ("exit", "quit", "exit-failed"):
            self.exit_code = 1 if command == "exit-failed" else 0
            return
        if not self.open:
            return
        states = {"working": 3, "waiting_input": 4, "ask": 4,
                  "idle": 0, "done": 0, "failed": 2}
        if command in states:
            state = states[command]
            # OSC, not a standalone BEL: no fabricated native bell notification.
            output(f"\x1b]9;4;{state};0".encode("ascii") + ST)
            self.waiting = state == 4
            self.message = f"Emitted OSC 9;4 state {state} for {command}; inspect native readback"
        elif command == "status":
            self.message = f"Received ack {self.ack}; native button actions received {self.clicks}"
        else:
            self.message = "Unknown command; use the fixed command list above"
        self.dirty = True

    def protocol(self, body):
        if not body.startswith(b"tsp;"):
            return
        parts = body.split(b";", 2)
        if len(parts) != 3:
            return
        try:
            event = json.loads(parts[2])
        except (ValueError, UnicodeDecodeError):
            raise RuntimeError("Malformed TSP reply") from None
        if not isinstance(event, dict):
            raise RuntimeError("TSP reply is not an object")
        if parts[1] == b"r" and event.get("r") == "hello":
            self.hello = event
            return
        if parts[1] != b"e":
            return
        if event.get("ev") == "error":
            raise RuntimeError("Native TSP error: " + json.dumps(event, ensure_ascii=True))
        if event.get("sf") != SURFACE:
            return
        kind = event.get("ev")
        if kind == "ack":
            seq = event.get("s")
            if type(seq) is int and 0 <= seq <= self.sequence:
                self.ack = max(self.ack, seq)
        elif kind == "gone":
            raise RuntimeError("Native fixture surface lost nodes")
        elif (kind == "action" and event.get("id") == "answer"
              and event.get("act") == "fixture-answer" and self.waiting):
            self.clicks += 1
            self.command("idle")
            self.message = f"Received native answer action {self.clicks}; emitted idle progress"
        elif kind == "send" and event.get("id") == "command":
            text = event.get("text")
            if isinstance(text, str) and len(text) <= 64:
                self.command(text)
        # The only editor is already focused; no native edit/undo features advertised.

    def feed(self, chunk):
        self.buffer.extend(chunk)
        if len(self.buffer) > 262144:
            raise RuntimeError("Oversized terminal input sequence")
        while self.buffer and self.exit_code is None:
            if self.pasting:
                end = self.buffer.find(b"\x1b[201~")
                if end < 0:
                    self.buffer[:] = self.buffer[-5:]
                    return
                del self.buffer[:end + 6]
                self.pasting = False
                self.message = "Bracketed paste ignored; type a fixture command or use native send"
                self.dirty = True
                continue
            if self.buffer[0] == 27:
                if len(self.buffer) < 2:
                    return
                if self.buffer[1] in (ord("_"), ord("]")):
                    end = self.buffer.find(ST, 2)
                    if end < 0:
                        return
                    body = bytes(self.buffer[2:end])
                    del self.buffer[:end + 2]
                    if body.startswith(b"877;"):
                        body = body[4:]
                    self.protocol(body)
                elif self.buffer[1] == ord("["):
                    end = next((i for i in range(2, len(self.buffer))
                                if 0x40 <= self.buffer[i] <= 0x7e), None)
                    if end is None:
                        return
                    sequence = bytes(self.buffer[:end + 1])
                    del self.buffer[:end + 1]
                    if sequence == b"\x1b[200~":
                        self.pasting = True
                    elif sequence.endswith(b"c") and self.hello is None:
                        self.rejected = True
                else:
                    del self.buffer[:2]
                continue
            char = self.buffer.pop(0)
            if char in (3, 4):
                self.exit_code = 0
            elif char in (10, 13):
                self.command(self.draft)
                self.draft = ""
                self.dirty = True
            elif char in (8, 127):
                self.draft = self.draft[:-1]
                self.dirty = True
            elif 32 <= char < 127 and len(self.draft) < 64:
                self.draft += chr(char)
                self.dirty = True

    def receive(self, timeout=None):
        if select.select([sys.stdin.fileno()], [], [], timeout)[0]:
            chunk = os.read(sys.stdin.fileno(), 4096)
            if not chunk:
                self.exit_code = 0
            else:
                self.feed(chunk)

    def render(self):
        # One outstanding frame is within every positive negotiated credit limit.
        if not self.dirty or self.sequence > self.ack:
            return
        if self.sequence == 0:
            main = node("main", "col", children=[
                node("title", "text", {"text": TITLE}),
                node("help", "text", {"text": HELP}),
                node("boundary", "text", {"text": "Synthetic signals only; no OMP/LLM workload."}),
                node("result", "text", {"text": self.message}),
                node("answer", "el", {"tag": "button", "text": "Answer synthetic ask",
                     "hidden": not self.waiting, "actions": {"click": "fixture-answer"}}),
            ])
            dock = node("dock", "col", children=[
                node("command", "editor", {"text": self.draft, "cursor": len(self.draft),
                     "placeholder": "Fixture command + Enter", "sendable": True}),
            ])
            ops = [["add", "main", SURFACE, None, main],
                   ["add", "dock", SURFACE, None, dock], ["focus", "command"]]
        else:
            ops = [["set", "result", {"text": self.message}],
                   ["set", "answer", {"hidden": not self.waiting}],
                   ["set", "command", {"text": self.draft, "cursor": len(self.draft)}]]
        self.sequence += 1
        tsp("f", {"sf": SURFACE, "s": self.sequence, "ops": ops})
        self.dirty = False

    def run(self):
        tsp("q", {"q": "hello", "v": [1], "app": SURFACE,
                  "ver": "1", "features": ["send"]})
        output(b"\x1b[c")
        deadline = time.monotonic() + 1.0
        while self.hello is None and not self.rejected and self.exit_code is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            self.receive(remaining)
        if self.exit_code is not None:
            return self.exit_code
        if self.hello is None or self.hello.get("v") != 1:
            raise RuntimeError("No TSP v1 hello; no native signals emitted")
        kinds = self.hello.get("kinds", [])
        if not all(kind in kinds for kind in ("col", "text", "el", "editor")):
            raise RuntimeError("Terminal lacks required fixture node kinds")
        credits = self.hello.get("credits")
        if type(credits) is not int or credits < 1:
            raise RuntimeError("Terminal did not grant frame credits")
        tsp("o", {"id": SURFACE, "mode": "inline", "title": TITLE, "role": SURFACE})
        self.open = True
        output(b"\x1b]9;4;0;0" + ST)
        self.render()
        while self.exit_code is None:
            self.receive()
            self.render()
        return self.exit_code


def main():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("This synthetic fixture requires its own Tern agent PTY.", file=sys.stderr)
        return 2
    if os.environ.get("TERN_TSP") == "0" or any(os.environ.get(key)
            for key in ("TMUX", "STY", "ZELLIJ")):
        print("TSP disabled or multiplexer present; fixture not started.", file=sys.stderr)
        return 2
    fixture = Fixture()
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    previous_handlers = {}
    failure = None
    code = 0
    try:
        tty.setraw(fd)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[sig] = signal.signal(sig, lambda number, frame: sys.exit(128 + number))
        code = fixture.run()
    except (RuntimeError, OSError) as error:
        failure = str(error)
        code = 2
    finally:
        try:
            if fixture.open:
                tsp("x", {"id": SURFACE, "keep": True})
            # Close before draining: leave no protocol replies for the next PTY reader.
            deadline = time.monotonic() + 0.15
            while time.monotonic() < deadline:
                remaining = deadline - time.monotonic()
                if select.select([fd], [], [], max(0, remaining))[0]:
                    if not os.read(fd, 4096):
                        break
        finally:
            termios.tcsetattr(fd, termios.TCSANOW, original)
            for sig, handler in previous_handlers.items():
                signal.signal(sig, handler)
    if failure:
        print("SYNTHETIC fixture error: " + failure, file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
