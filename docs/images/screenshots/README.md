# README gallery

Captured on macOS from V2MacDev with `-debugDemoData YES`. All servers, subscription usage, latency, and speed values are fixtures, not live measurements. The demo list has one server per supported protocol (VLESS REALITY, VLESS XHTTP / WS / gRPC, VMess, Trojan, Hysteria2, Shadowsocks, WireGuard, SOCKS, HTTP). No server was connected and TUN stayed off. The development proxy port is 10818; the installed app defaults to 10808.

Every PNG is `screencapture -l <window id>`, so it keeps macOS's window shadow. Sheets are captured with their parent window and cropped to the sheet (`server-editor.png`, `add-subscription.png`); `sharing.png` is cropped to the inspector and its QR popover. `main.png` is reduced to 1440 pixels wide; the other PNGs retain their captured resolution. The main window is 1640×720 so the Type column is not truncated.

- `rule-editor-simple.png`: the Rules window with made-up rules passed as `-debugRulesFile <rules.json>` (shown, never saved). Write that file with `Rule.encode`, not by hand.
- `proxifier-import.png`: the Rules window's ⋯ menu → Import Rules… with a made-up `.ppx` profile.
- `rule-builder-countries.png`: a rule's Browse… sheet, Countries tab. Never capture the Apps tab: it lists the Mac's real installed apps.
- `add-subscription.png`: the + button with a made-up `sub.example.com` link, cancelled afterwards.
- `sandbox-window.png`, `sandbox-store.png`: the Secure Sandbox and its store.

The GIFs show captured UI states, held for about 1.5 seconds per step and looped:

- `server-browsing.gif`: All → subscription → sort by delay → Favorites → search for Frankfurt.
- `settings-tour.gif`: General → Proxy → Routing → Connection → Servers → Notifications → Core → About.

GIFs are encoded with FFmpeg at 960 pixels wide for server browsing and 840 pixels wide for settings, using a 128-color palette, Bayer dithering, and rectangle difference optimization. Keep TUN off and use no real subscription URLs or credentials. Update the gallery in all root READMEs together.
