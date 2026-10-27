# Contributing

Thanks for looking. Longarm is small enough to read end to end: start with
[Architecture](docs/architecture.md), then the comment at the top of each file.

## Building

See [Getting started](docs/getting-started.md). In short:

```bash
mac/build.sh --run                      # the Mac app
android/deploy.sh                       # the phone app, installed over adb
cd server && npm ci && npm test         # the rendezvous server and its tests
```

The server's type check is `npm run check` (in `server/`).

## Testing your change

- **Server:** `npm test` covers the rendezvous protocol (signing in, allow lists, introductions,
  limits). Add a test for anything you change there.
- **Mac and phone:** there are no automated tests yet, so describe how you tried your change:
  what you did on the phone, and what the Mac's log (`~/Library/Logs/Longarm/longarm.log`) shows.
- **Internet connections** can be tried on one network with the server running on the Mac (see
  [Internet connections](docs/internet.md#trying-it-without-a-server)).

## Code style

- **Match the code around you**: its naming, structure and comment style.
- **Plain names**: `connection`, `phone`, `message`, not abbreviations.
- **Comments say why**, in plain sentences: what something is for, or what would go wrong without
  it. Each file starts with one describing its job; keep it true when the job changes.
- **No new dependencies** without a good reason. The Mac app uses only Apple's frameworks and
  WebRTC; the server has one dependency.
- **Security-sensitive changes** (pairing, keys, the join code, the server) should say in the pull
  request what they change about [the security model](docs/security.md).

## Commits and pull requests

- One change per commit, with a short summary line in the imperative ("Show Direct or Relay for a
  few seconds") and, if it helps, a paragraph saying what changed and why.
- In the pull request, say what you changed, why, and how you tested it. Screenshots or a short
  recording help for anything on screen.

## Reporting bugs

Open an issue with what you did, what you expected and what happened, plus the Mac's log around that
time. For security problems, see [SECURITY.md](SECURITY.md) instead: please don't open a public
issue.
