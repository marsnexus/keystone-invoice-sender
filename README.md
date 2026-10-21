# Keystone invoice sender

Adds **Send to counter** to the macOS print dialog. A customer prints their invoice to it from
the shop's shared Mac, and it arrives at the counter, already read, for staff to check and turn
into an order.

## How it fits together

```
customer, at the shared Mac                         staff, at the counter
──────────────────────────                          ─────────────────────
Safari → File → Print → PDF ▾ → Send to counter
        │
        └─ send-to-counter.sh ── HTTPS ──▶ Keystone ── reads the invoice ──▶ "Invoices from the
           (curl, this machine's token)                                     customer iMac" list
        ◀── "Sent. Please go to the counter." ─┘                            Open → Create order
```

The sender only ever dials **out**. Nothing is stored on the Mac but the pairing and a log line:
the PDF macOS made is sent (from a temporary copy, removed afterwards) and left where macOS put it. The server decides everything else — what the invoice
says, whether it was sent already, how many may be sent in an hour — so a change there never
means revisiting the shop.

It is a macOS **PDF Service**: an executable in `~/Library/PDF Services/` is listed under the
print dialog's **PDF ▾** menu, beside *Save as PDF*, in every app. No printer driver, no CUPS
queue.

## Install (on the Mac customers print from)

It needs only `bash`, `curl` and `plutil`, which ship with macOS — **no Homebrew, no git, no
Node, and no admin password.** It installs for the account that runs it, so run it as the
account customers use.

1. Get the sender onto the Mac. **Not `git clone`** — on a bare Mac `git` starts the ~1 GB Xcode
   command line tools download. `curl` and `tar` ship with macOS:

   ```
   mkdir -p ~/keystone-invoice-sender && cd ~/keystone-invoice-sender
   curl -fsSL https://github.com/marsnexus/keystone-invoice-sender/archive/refs/heads/main.tar.gz \
     | tar -xz --strip-components=1
   ```

   The same command updates an existing install; run `./install.sh` again afterwards to copy the
   new script into the menu. The pairing lives in `~/.keystone-invoice-sender/`, so
   re-extracting never touches it.

2. Get a token, **on the machine that has the Keystone server code — not on this Mac**:

   ```
   pnpm invoice-sender:token <tenant-slug>
   ```

   **The token is shown once and cannot be recovered** — the server keeps only its hash. Lost it?
   Run the command again with `--rotate`; the old token stops working at once.

3. Install, with the site's own address and the label customers should see:

   ```
   ./install.sh --token <TOKEN> --server https://your-site --label "Send to counter · 发送到柜台"
   ```

   It writes the pairing, adds the menu entry and **checks the pairing with the server** (a
   request that stores nothing). `✓ Paired with …` means it is ready.

4. Try it: open any page in **Safari**, **File → Print**, open **PDF ▾** at the bottom left,
   choose your label. A dialog says what happened.

> **Use Safari.** Chrome shows its own print preview, which has no PDF menu; it only reaches the
> macOS dialog through *Print using system dialog* (⌥⌘P).

Check the pairing at any time with `./install.sh --check`. Remove the menu entry with
`./install.sh --uninstall` (the pairing is left; delete `~/.keystone-invoice-sender/` to forget
the token).

### Where things live

| | |
|---|---|
| `~/.keystone-invoice-sender/config.json` | the server and token, mode 600 — never inside this folder |
| `~/Library/PDF Services/<label>` | a copy of `send-to-counter.sh`; its file name is the menu label |
| `~/Library/Logs/keystone-invoice-sender.log` | one line per send: the HTTP status and the outcome. Never the token, never the invoice |

## What the customer sees

The server's own words, in English and Chinese, in a dialog that closes itself after 30 seconds:

| | |
|---|---|
| sent | *Sent. Please go to the counter.* |
| the same invoice again | *Already sent. Please go to the counter.* — it is one invoice at the counter, read once |
| an invoice that is already an order | *This invoice is already an order at the counter.* |
| too many sent in a short time | *Please hand your invoice to the staff.* |
| anything else — no network, a wrong token, not paired | *It could not be sent. Please hand your invoice to the staff.* |

The token sits on a machine customers use, so treat it as public: all it can do is add an invoice
to that one site's list, within limits the server sets. Staff still check every invoice against
the person in front of them before an order exists.

## Troubleshooting

- **The label is not in the PDF menu.** Quit Safari and open it again; the menu is read when the
  app starts. Check the file is there and executable: `ls -l ~/Library/PDF\ Services/`.
- **Nothing happens when it is chosen.** Look at `~/Library/Logs/keystone-invoice-sender.log`. No
  line at all means macOS did not run it: run `./install.sh` again (it clears the download
  quarantine flag).
- **"It could not be sent".** `./install.sh --check` names the reason: the address, the token, or
  the network.

## Testing it

```
bash test/selftest.sh
```

Runs the script against a stubbed `curl` and `osascript` for every answer the server can give.
Needs a Mac (`plutil` reads the JSON).

## License

MIT — see `LICENSE`.
