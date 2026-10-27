# tomd

Web pages → Markdown, plus a CORS passthrough, for an **allowlist** of sites.
Sites so far: Nim forum threads and Google Scholar profiles. Runs at
**tomd.pietroppeter.xyz** (deployed with [Disco](https://disco.cloud)).

## Usage

Put tomd's address in front of a URL (the scheme is optional):

```
https://tomd.pietroppeter.xyz/https://forum.nim-lang.org/t/12345
https://tomd.pietroppeter.xyz/forum.nim-lang.org/t/12345
https://tomd.pietroppeter.xyz/https://scholar.google.com/citations?user=XXXXXXXXXXXX
```

| Route | What |
|---|---|
| `GET /` | page: paste a URL, copy the Markdown |
| `GET /<url>` | Markdown for `<url>` (`text/markdown`) |
| `GET /md?url=<url>` | same, URL as a query parameter |
| `GET /cors/<url>` | raw response with `Access-Control-Allow-Origin: *` |
| `GET /healthz` | `ok` |

## Nim forum converter

`src/tomd/nimforum.nim` calls nimforum's own JSON API server-side (see
[nim-lang/nimforum `src/forum.nim`](https://github.com/nim-lang/nimforum/blob/master/src/forum.nim));
it does not go through `/cors/`:

- `/posts.json?id=<thread>`: thread and posts. Only the first and last 10 posts
  are full; the ids of the ones in between are in each post's `moreBefore`.
- `/specific_posts.json?ids=[..]`: fills that gap.
- `/post.rst?id=<post>`: raw source of the latest revision (RST with Markdown
  support), used for post bodies.

Output: YAML front matter for the thread, then each post as a YAML block
opened by `---` and closed by `...` (YAML's end-of-document marker, also
accepted by pandoc), followed by its body. Bodies are left exactly as typed (so
they may contain RST, headings, or `---` of their own); to split posts, match a
`---` line followed by `post:`. Closing with `...` rather than `---` keeps
Markdown renderers from turning the last YAML line into a heading.

```markdown
---
title: "Some thread"
source: https://forum.nim-lang.org/t/12345
category: "Default"
author: "alice"
created_at: 2026-09-23T17:18:00Z
updated_at: 2026-09-24T08:02:00Z    # latest post or edit
posts: 2
---

---
post: 1
id: 100
url: https://forum.nim-lang.org/t/12345#100
author: "alice"
created_at: 2026-09-23T17:18:00Z
updated_at: 2026-09-24T08:02:00Z    # only if edited
edits: 1
likes: ["bob"]
...

First post.

---
post: 2
id: 101
url: https://forum.nim-lang.org/t/12345#101
author: "bob"
created_at: 2026-09-23T18:02:00Z
reply_to: 1                         # post number; reply_to_id is the post id
reply_to_id: 100
reply_to_author: "alice"
...

Reply.
```

A thread that does not exist gives a 404.

It works on its own as a CLI too:

```sh
nim c -d:release -d:ssl -o:bin/nimforum src/tomd/nimforum.nim
./bin/nimforum https://forum.nim-lang.org/t/12345 -o:thread.md   # --html for rendered bodies
```

## Google Scholar converter

`src/tomd/scholar.nim` turns a profile page (`/citations?user=<id>`) into YAML
front matter (name, affiliation, interests, citations / h-index / i10-index)
and a table of articles, most cited first. Scholar has no API, so it parses the
page HTML, 100 articles per request, up to 500 articles. Scholar's robots.txt
allows profile pages, but Scholar often answers server IPs with a CAPTCHA or a
429: tomd then answers 503 with that reason rather than an empty profile. The
`scholar` CI job warns instead of failing when that happens to the runner.

```sh
nim c -d:release -d:ssl -o:bin/scholar src/tomd/scholar.nim
./bin/scholar 'https://scholar.google.com/citations?user=XXXXXXXXXXXX' -o:profile.md
```

## Run / deploy

```sh
nim c -d:release -d:ssl -o:bin/tomd src/tomd.nim && PORT=8000 ./bin/tomd
```

Disco: `Dockerfile` + `disco.json` (port 8000). `FORUM_BASE` overrides where
forum data is fetched from (for tests).

## Adding a site

Write a module with `canonical(u: Uri): string` (validate and normalize the URL,
used as the cache key; raise `ValueError` if unsupported) and
`render(canon: string): Future[string]`, then add it to `Converters` in
`src/tomd.nim`. The host is then allowlisted for both Markdown and `/cors/`.

## Guard rails

Not an open proxy: every outgoing request goes to an allowlisted host. Plus:
GET only, per-IP rate limit (20/min, from `X-Forwarded-For` as set by Disco's
Caddy), at most 4 uncached conversions in flight, a 10-minute cache (which also
keeps nimforum view counts from being inflated, since `posts.json` counts a
view), and a 5 MB cap on passthrough responses.

## Why the page has no CORS problem

The page and the API share one origin, so the browser never makes a
cross-origin request. The `Access-Control-Allow-Origin: *` headers are for
*other* pages (e.g. static sites) calling tomd.

## Why asynchttpserver, not Mummy

tomd mostly waits on other sites: a conversion is several outgoing HTTP calls.
std `asyncdispatch` handles that on one thread, so the cache, rate limiter and
in-flight counter are plain globals without locks, and there are no dependencies.
[Mummy](https://github.com/guzba/mummy) (used by
[disco-nim-mummy](https://github.com/pietroppeter/disco-nim-mummy)) runs blocking
handlers on worker threads: each outgoing call would hold a worker, and the shared
state would need a `Lock`. Worth switching if tomd needs WebSockets, or if
asynchttpserver misbehaves behind Caddy.
