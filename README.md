<div align="center">

# Attention

**My highly opinionated attention rail for Tern.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)
![Tern 0.9.9+](https://img.shields.io/badge/Tern-0.9.9%2B-blue)

</div>

---

<p align="center">
  <img src="docs/media/attention.png" alt="Attention in a left rail: Working and Attention queues over the Workspace" width="420">
</p>

Clicking Tern's stock ⌘⇧I needs-attention inbox was too many clicks, so I built this! Why click many times when one click better.

- **Working, then Attention.** I run it as a left rail. The top lists the tabs whose agents are working right now; below that, what needs you: a question, a finished reply, a turn that failed. Swap the two from either section's **⋯** menu.
- **A Workspace underneath** that matches the ergonomics of the native ⌘B sidebar (hosts, sessions, tabs), bar a few things Tern's plugin API can't do yet.
- **Next / Previous buttons.** I find myself using Previous more than Next.

Enjoy! If you have any issues or suggestions, feel free to open an issue or PR.

## Install

```sh
tern plugin install github.com/baekjosh/tern-attention
```

Then choose **Attention: Enable here** in Tern's command palette. The rail mounts on the left by default (flip Settings → tabs to Horizontal and it reads as a native sidebar), and Settings still holds the default (Bottom / Right / Left); per-tab relayout lives in the palette (**Attention: Use Right in this tab**, and friends).

Attention mounts only on the local host. Remote sessions are shared with their other clients, so the plugin never places your private workspace rail there. Updating removes older Attention canvases from connected remote hosts; their chats and other panes stay intact.

The full behavioral spec, the placement engine, and the proof boundaries live in [docs/REFERENCE.md](docs/REFERENCE.md).

## License

MIT — see [LICENSE](LICENSE).
