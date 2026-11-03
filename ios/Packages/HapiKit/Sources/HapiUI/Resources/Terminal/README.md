# Embedded terminal

Built from `web/src/lib/ios-terminal.ts` using the existing locked web dependencies:
xterm 6.0.0, addon-fit 0.11.0 and Socket.IO client. Runtime assets are bundled,
never fetched from a CDN. The page only connects to the paired Hub origin.

From the source repository root, regenerate with:

```sh
bun build web/src/lib/ios-terminal.ts --target browser --format iife --minify --outfile ios/Packages/HapiKit/Sources/HapiUI/Resources/Terminal/terminal.js
cp web/node_modules/@xterm/xterm/css/xterm.css ios/Packages/HapiKit/Sources/HapiUI/Resources/Terminal/terminal.css
```

Third-party licenses are preserved in `THIRD_PARTY_NOTICES.txt` and the LICENSE files.

Command mode gates keyboard and clipboard input, **not** xterm protocol replies.
Disabling all stdin drops cursor-position responses and can stall shell startup.
Native connections use WebSocket directly to avoid intermittent WKWebView polling-upgrade input loss.
Socket reconnects reuse the terminal ID and reset the screen before Hub replay.
Leaving/backgrounding detaches the viewer; the Hub/CLI owns idle shell cleanup.
