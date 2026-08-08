# fm-grant - the captain-authorized grant vault

`bin/fm-grant.sh` gives firstmate a bounded, captain-authorized window of promptless access to a secret, so the fleet stops hitting av's approval dialog on every use.
Exact flags, subcommands, state fields, and concurrency mechanics are owned by the script's own header comment and `bin/fm-grant.sh --help`; this page owns what the tool is, what it is not, and how to operate it safely.

## What this is, honestly

fm-grant is a convenience window with receipts, NOT a security control.
Once `grant` imports a secret into the macOS Keychain (service `firstmate-grant`), ANY same-user process can read it silently with `security find-generic-password -w -s firstmate-grant -a KEY` - no grant, no expiry, and no fm-grant involved - until `forget` removes the item.
The grant count and expiry are cooperative bookkeeping plus an audit trail for firstmate's own well-behaved callers: they bound firstmate's polite usage, not the machine.
`forget` is the only real revocation; `revoke` and expiry close the bookkeeping window but leave the item readable.
Importing a key is therefore a permanent runtime-gate downgrade for that key: its at-rest storage is Keychain-grade either way, but the per-use human approval is gone for every same-user process, not just for firstmate.
This trade is acceptable because the threat being solved is prompt fatigue from firstmate's own fleet, not malware: a hostile same-user process could equally wrap `av` or read agent memory, so that game is already lost before fm-grant enters it.

## Operating it

Grant only on the captain's explicit instruction, quoting their words in the required `--reason`, which is logged and shown in `status`.
Any secret is eligible; the captain's instruction is the scope.
The first grant for a key runs one av approval shaped as `av inject +KEY -- fm-grant.sh _store KEY`, and fm-grant announces loudly before the dialog fires that approving it permanently moves the key under the weaker promptless custody described above.
Run secret-needing commands as `bin/fm-grant.sh exec KEY [KEY...] -- <cmd> [args...]`, which resolves each key and injects the values into the child command's environment only.
No fm-grant output ever contains a value, and there is deliberately no public `get`, because a value printed to stdout lands in agent transcripts, panes, and reports.
Without an active grant for every requested key, `exec` prints one loud stderr line and then execs `av inject +KEY... -- <cmd>` directly, so behavior degrades to the ordinary prompting path, no grant is consumed, and the value never transits fm-grant.
Grant bounds (`--uses N`, `--until <N><s|m|h|d>`, `--permanent`) combine, and whichever limit comes first wins; a use is one key retrieval, and expiry is applied lazily on every exec and status.
Risky grant shapes warn on stderr but never block: `--permanent`, uses over 100, deadlines past 30 days, and names on the small consequence list (PAYMENT, TEBEX, STRIPE, PROD, DEPLOY, SIGNING).

## Never bless fm-grant.sh

Never `av bless` fm-grant.sh itself.
The one human checkpoint left in this design is the av approval on first import; blessing the script would delete that checkpoint and make every future import promptless and unbounded.

## State, audit, and limits

Grant records are per-secret shell-parseable files under `<state>/grants/<KEY>` plus one append-only `<state>/grants.log`, resolved per home so secondmate homes never share grants.
`status` lists every imported key - including expired and revoked ones that remain silently readable - with its bounds, reason, and the audit log path, and restates the exposure above.
Trailing newlines are stripped on import and retrieval, which is fine for tokens.
The tool is macOS-only: it needs `security` and `av`.
`tests/fm-grant.test.sh` pins this contract against fake `security` and `av` shims and never touches the real login Keychain or a real av dialog.
