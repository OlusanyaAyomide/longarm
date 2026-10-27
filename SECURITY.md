# Security policy

Longarm controls a Mac remotely, so security reports are very welcome and taken seriously.

## Reporting a vulnerability

Please report it **privately**, not in a public issue: use **Report a vulnerability** on the
repository's [Security tab](https://github.com/OlusanyaAyomide/longarm/security/advisories/new).

Include what's affected (the Mac app, the phone app, the server or the deploy scripts), how to
reproduce it, and what an attacker would need to exploit it (for example: on the same network,
holding a paired phone, controlling the rendezvous server).

We aim to reply within a week, and once it's fixed we'll credit you in the release notes if you'd
like.

## Supported versions

Longarm is pre-1.0; fixes go into `main`.

## The security model

[docs/security.md](docs/security.md) describes how Longarm decides who gets in, what each part can
see, and its known limits. Reports that one of those guarantees doesn't hold are exactly what we
want to hear about.
