<div align="center">

# Attention

**A needs-attention rail for Tern. No bell icon required.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)
![Tern 0.9.9+](https://img.shields.io/badge/Tern-0.9.9%2B-blue)

</div>

---

[![Attention demo: the Attention queue and per-tab placement](docs/media/demo.gif)](docs/media/demo.mp4)

Clicking Tern's stock ⌘⇧I needs-attention inbox was too many clicks, so I built this! Why click many times when one click better.

- **A needs-attention view that's just there.** I keep it pinned below my panes, sticky across all windows. No clicking a bell icon to see what needs me.
- **A Later tab** to punt things to. Tab minimization is probably coming soon, but until then I'm satisfied with this.
- **A Workspace tab** that's pretty much the same thing as the ⌘B side window. Honestly I rarely use it — the simplicity of the attention inbox suits the monkey brain better: know what button to press next, instead of navigating sessions and tabs. That's what ⌘B is for; I keep the stock left sidebar and the attention pane at the bottom.
- **Next / Previous buttons.** I find myself using Previous more than Next.

It's factual: native runtime state and your explicit choices only. No AI inference, no prompts sent on your behalf, nothing leaves the machine. There's also a read-and-jump phone queue — your iPhone mirrors the queue from your Mac, and tapping a row jumps to that conversation.

## Install

```sh
tern plugin install github.com/baekjosh/tern-attention
```

Then choose **Attention: Enable here** in Tern's command palette. The rail mounts at the bottom by default; Settings holds the default (Bottom / Right / Left), and per-tab relayout lives in the palette (**Attention: Use Right in this tab**, and friends).

The full behavioral spec, the placement engine, and the proof boundaries live in [docs/REFERENCE.md](docs/REFERENCE.md).

## License

MIT — see [LICENSE](LICENSE).
